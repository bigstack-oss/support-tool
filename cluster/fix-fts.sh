#!/usr/bin/env bash
# All-in-one: new Keycloak service user for cube-cos-api + cube-cos-api config +
# Skyline console credential, with the same user everywhere.
#
#   1. Keycloak (https://<IP>:10443/auth, realm master): create <newuser> (or
#      normalise it and reset its password if it exists), add it to group
#      cube-admins, verify it can log in.
#   2. /etc/cube/api/cube-cos-api.yaml and .yaml.in: set auth.username/password.
#   3. cubectl node rsync both files, restart cube-cos-api on all nodes.
#   4. Skyline console bundle: replace the hard-coded {username,password} pair,
#      rebuild the .gz, cubectl node rsync, compare checksums on every node.
#      The cube-cos-api tokens check is retried for 60s; if it still fails it is
#      reported but the bundle is patched anyway (Keycloak already accepted it).
#
# Run as root on a CubeCOS node. Requires: bash, python3, gzip, curl, grep, awk,
# md5sum, cubectl.
# Prompts for <IP>, <admin user>, <admin pass>, <new user>, <new pass>;
# or set KC_HOST, KC_USER, KC_PASS, NEW_USER, NEW_PASS.
#
# Options:
#   --no-skyline   stop after step 3
#   --dc NAME      datacenter name for the tokens check (default: auto-discovered)
#   -h, --help     show this help
# Environment: SKYLINE_STATIC_DIR, BACKUP_DIR (default /root)
# Exit: 0 = done; 1 = stopped on error; 2 = done but the tokens check failed or
# a checksum differs.
set -Eeuo pipefail
export LC_ALL=C

CFG_DIR=/etc/cube/api
FILES=("$CFG_DIR/cube-cos-api.yaml" "$CFG_DIR/cube-cos-api.yaml.in")
GROUP=cube-admins
BACKUP_DIR="${BACKUP_DIR:-/root}"
STATIC_DIR="${SKYLINE_STATIC_DIR:-/usr/local/lib/python3.9/site-packages/skyline_console/static}"
PAIR_RE='\{username:"([^"\\]|\\.)*",password:"([^"\\]|\\.)*"\}'

die() { echo "STOP: $*" >&2; exit 1; }
info() { echo "==> $*"; }
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; .bak copies are in $BACKUP_DIR." >&2' ERR

run_skyline=1 dc=""
while (( $# )); do
    case "$1" in
        --no-skyline) run_skyline=0 ;;
        --dc) shift; dc="${1:-}"; [[ -n $dc ]] || die "--dc needs a value" ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

(( EUID == 0 )) || die "Run as root"
for tool in python3 gzip curl grep awk md5sum cubectl; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
for f in "${FILES[@]}"; do [[ -f $f ]] || die "Missing file: $f"; done

# ------------------------------------------------------------------ inputs
ip=${KC_HOST:-}; kuser=${KC_USER:-}; kpass=${KC_PASS:-}
nuser=${NEW_USER:-}; npass=${NEW_PASS:-}
[[ -n $ip ]] || read -r -p "Keycloak <IP address>: " ip
[[ $ip =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid IP/host: '$ip'"
[[ -n $kuser ]] || read -r -p "Keycloak admin <user> [admin]: " kuser
kuser=${kuser:-admin}
[[ -n $kpass ]] || { read -r -s -p "Keycloak admin <pass> [admin]: " kpass; echo; }
kpass=${kpass:-admin}
[[ -n $nuser ]] || read -r -p "New user [cube-cos-api]: " nuser
nuser=${nuser:-cube-cos-api}
[[ -n $npass ]] || { read -r -s -p "New user password [Cube-cos-api@$ip]: " npass; echo; }
npass=${npass:-Cube-cos-api@$ip}

export KC_URL="https://$ip:10443/auth" KC_ADMIN=$kuser KC_ADMIN_PASSWORD=$kpass \
       NEW_USER=$nuser NEW_PASS=$npass KC_GROUP=$GROUP
unset kpass

# ---- pre-flight for the Skyline step, so nothing is changed if it cannot run
bundle="" name="" addr="" tokens_failed=0
if (( run_skyline )); then
    [[ -d $STATIC_DIR ]] || die "Static directory not found: $STATIC_DIR (use --no-skyline to skip)"
    hits=()
    for f in "$STATIC_DIR"/*.js; do
        if grep -qE "$PAIR_RE" "$f" && grep -q 'datacenters' "$f" && grep -q 'tokens' "$f"; then
            hits+=("$f")
        fi
    done
    (( ${#hits[@]} == 1 )) || {
        printf 'Found %d candidate bundle(s) in %s:\n' "${#hits[@]}" "$STATIC_DIR" >&2
        printf '  %s\n' "${hits[@]}" >&2
        die "Expected exactly one bundle with a hard-coded credential pair."
    }
    bundle="${hits[0]}"; name="$(basename "$bundle")"
    addr="$(grep -ohE 'listen +[0-9.]+:9999' /etc/nginx/nginx.conf 2>/dev/null | head -1 | awk '{print $2}' || true)"
    info "Skyline bundle: $bundle"
fi

# ------------------------------------------- 1. Keycloak user + group
# TLS verification is off: the IdP uses a private CA. Credentials stay in the
# environment, not in argv.
info "Keycloak $KC_URL: creating '$nuser' in group '$GROUP'"
python3 - <<'PY'
import json, os, ssl, sys, urllib.error, urllib.parse, urllib.request

ctx = ssl._create_unverified_context()
base = os.environ["KC_URL"].rstrip("/")
user, pw, group = os.environ["NEW_USER"], os.environ["NEW_PASS"], os.environ["KC_GROUP"]

def call(method, url, data=None, headers=None, form=False):
    body = None
    h = dict(headers or {})
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
    req = urllib.request.Request(url, body, h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace"), e.headers

st, tok, _ = call("POST", base + "/realms/master/protocol/openid-connect/token",
                  {"grant_type": "password", "client_id": "admin-cli",
                   "username": os.environ["KC_ADMIN"], "password": os.environ["KC_ADMIN_PASSWORD"]},
                  form=True)
if st != 200:
    sys.exit("admin token request failed (%s): check IP, admin user and password" % st)
auth = {"Authorization": "Bearer " + tok["access_token"]}
adm = base + "/admin/realms/master"

st, groups, _ = call("GET", adm + "/groups?search=" + urllib.parse.quote(group), headers=auth)
def find(gs):
    for g in gs or []:
        if g.get("name") == group:
            return g["id"]
        sub = find(g.get("subGroups"))
        if sub:
            return sub
gid = find(groups) if st == 200 else None
if not gid:
    sys.exit("group '%s' not found in realm master" % group)

rep = {"username": user, "enabled": True, "emailVerified": True,
       "firstName": user, "lastName": "service", "email": user + "@cube.local"}
st, out, hdr = call("POST", adm + "/users", rep, auth)
if st == 201:
    uid = hdr["Location"].rstrip("/").rsplit("/", 1)[1]
    print("created user %s (%s)" % (user, uid))
elif st == 409:
    st, found, _ = call("GET", adm + "/users?exact=true&username=" + urllib.parse.quote(user), headers=auth)
    found = [u for u in (found or []) if u.get("username", "").lower() == user.lower()] if st == 200 else []
    if not found:
        sys.exit("user exists but could not be looked up")
    uid = found[0]["id"]
    print("user %s already exists (%s); normalising and resetting password" % (user, uid))
    # a hand-made user may be disabled, unverified or carry required actions
    fix = {"enabled": True, "emailVerified": True, "requiredActions": []}
    for k, v in (("firstName", user), ("lastName", "service"), ("email", user + "@cube.local")):
        if not found[0].get(k):
            fix[k] = v
    st, out, _ = call("PUT", "%s/users/%s" % (adm, uid), fix, auth)
    if st not in (200, 204):
        print("WARNING: could not normalise existing user (%s): %s" % (st, out))
else:
    sys.exit("create user failed (%s): %s" % (st, out))

st, out, _ = call("PUT", "%s/users/%s/reset-password" % (adm, uid),
                  {"type": "password", "value": pw, "temporary": False}, auth)
if st not in (200, 204):
    sys.exit("set password failed (%s): %s" % (st, out))
print("password set")

st, out, _ = call("PUT", "%s/users/%s/groups/%s" % (adm, uid, gid), headers=auth)
if st not in (200, 204):
    sys.exit("add to group failed (%s): %s" % (st, out))
print("member of %s" % group)

st, out, _ = call("POST", base + "/realms/master/protocol/openid-connect/token",
                  {"grant_type": "password", "client_id": "admin-cli", "username": user, "password": pw},
                  form=True)
if st != 200:
    sys.exit("new user cannot log in (%s): %s" % (st, out))
print("new credential verified against Keycloak")
PY

# ------------------------------------------- 2. rewrite the yaml files
info "Backing up to $BACKUP_DIR (existing .bak files are kept)"
for f in "${FILES[@]}"; do cp -an "$f" "$BACKUP_DIR/$(basename "$f").bak"; done

info "Updating auth credentials"
python3 - "${FILES[@]}" <<'PY'
import json, os, re, sys, tempfile, shutil

user, pw = os.environ["NEW_USER"], os.environ["NEW_PASS"]

def scalar(v):
    # plain scalar when safe, otherwise a JSON (valid YAML) double-quoted string
    if re.fullmatch(r"[A-Za-z0-9_./][A-Za-z0-9_./@+=%-]*", v):
        return v
    return json.dumps(v)

pat = re.compile(
    r"^(?P<ind>[ \t]*)auth:[ \t]*\n"
    r"(?P<i2>[ \t]+)realm:[ \t]*(?P<realm>[^\n]*)\n"
    r"[ \t]+username:[^\n]*\n"
    r"[ \t]+password:[^\n]*(?P<nl>\n|$)", re.M)

for path in sys.argv[1:]:
    with open(path, encoding="utf-8", newline="") as fh:
        src = fh.read()
    hits = pat.findall(src)
    if len(hits) != 1:
        sys.exit("%s: expected exactly 1 auth block (realm/username/password), found %d" % (path, len(hits)))
    def repl(m):
        i2 = m.group("i2")
        return ("%sauth:\n%srealm: %s\n%susername: %s\n%spassword: %s%s" %
                (m.group("ind"), i2, m.group("realm"), i2, scalar(user), i2, scalar(pw), m.group("nl")))
    out = pat.sub(repl, src, count=1)
    if out == src:
        print("%s: already up to date" % path)
        continue
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(out)
        shutil.copymode(path, tmp)
        st = os.stat(path)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
        print("%s: updated" % path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
PY

# ------------------------------------------- 3. sync + restart
info "Syncing yaml files to all CubeCOS nodes"
cubectl node rsync "${FILES[0]}"
cubectl node rsync "${FILES[1]}"

info "Restarting cube-cos-api on all nodes"
cubectl node exec -p "systemctl restart cube-cos-api"
sleep 5

if (( ! run_skyline )); then
    echo "Skipped Skyline patch (--no-skyline)."
    echo "Done. cube-cos-api now authenticates to Keycloak as '$nuser'."
    exit 0
fi

# ------------------------------------------- 4. skyline console bundle
if [[ -z $dc ]]; then
    [[ -n $addr ]] || die "Cannot find the console listen address in /etc/nginx/nginx.conf; re-run with --no-skyline and use fix-skyline-401.sh --skip-validate."
    dc="$(curl -sk "https://$addr/cos-api/v1/datacenters" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data") or []
loc = [x for x in d if x.get("isLocal")] or d
print(loc[0]["name"] if loc else "")
' 2>/dev/null || true)"
    [[ -n $dc ]] || die "Could not discover the datacenter name; pass --dc NAME."
fi

info "Validating credential against cube-cos-api tokens endpoint (datacenter $dc)"
# cube-cos-api may need a while after the restart, so retry for up to 60s.
# Keycloak already accepted this credential above, so a persistent failure here
# is reported but does not stop the Skyline patch.
code=000 body=""
for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    resp="$(python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"name": os.environ["NEW_USER"], "password": os.environ["NEW_PASS"]}))
' | curl -sk -w '\n%{http_code}' -X POST \
        "https://$addr/cos-api/v1/datacenters/$dc/tokens" \
        -H 'Content-Type: application/json' --data-binary @- || true)"
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    [[ $code == 200 || $code == 201 ]] && break
    echo "  attempt $try: HTTP $code, retrying in 5s"
    sleep 5
done
if [[ $code == 200 || $code == 201 ]]; then
    echo "Credential accepted ($code)"
else
    echo "WARNING: tokens endpoint still returns $code after 60s; applying the Skyline patch anyway." >&2
    echo "  response: ${body:0:300}" >&2
    echo "  cube-cos-api log:" >&2
    journalctl -u cube-cos-api --since "-5 min" --no-pager 2>/dev/null \
        | grep -i -E "invalid_grant|failed to generate token|keycloak|401" | tail -5 | sed 's/^/    /' >&2 || true
    tokens_failed=1
fi

info "Backing up Skyline bundle to $BACKUP_DIR (existing .bak files are kept)"
cp -an "$bundle" "$BACKUP_DIR/$name.bak"
[[ -f $bundle.gz ]] && cp -an "$bundle.gz" "$BACKUP_DIR/$name.gz.bak"

info "Patching $name"
python3 - "$bundle" <<'PY'
import json, os, re, shutil, sys, tempfile
path = sys.argv[1]
user, pw = os.environ["NEW_USER"], os.environ["NEW_PASS"]
pat = re.compile(r'\{username:"(?:[^"\\]|\\.)*",password:"(?:[^"\\]|\\.)*"\}')
with open(path, encoding="utf-8", newline="") as fh:
    src = fh.read()
hits = pat.findall(src)
if len(hits) != 1:
    sys.exit("expected exactly 1 credential pair, found %d" % len(hits))
new = "{username:%s,password:%s}" % (json.dumps(user), json.dumps(pw))
if hits[0] == new:
    print("already up to date")
    sys.exit(0)
out = pat.sub(lambda m: new, src, count=1)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
        fh.write(out)
    shutil.copymode(path, tmp)
    st = os.stat(path)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, path)
    print("patched")
finally:
    if os.path.exists(tmp):
        os.remove(tmp)
PY
unset npass NEW_PASS KC_ADMIN_PASSWORD

info "Rebuilding $name.gz"
gzip -9 -n -c "$bundle" > "$bundle.gz.new"
if [[ -f $bundle.gz ]]; then
    chmod --reference="$bundle.gz" "$bundle.gz.new"
    chown --reference="$bundle.gz" "$bundle.gz.new"
else
    chmod --reference="$bundle" "$bundle.gz.new"
fi
mv -f "$bundle.gz.new" "$bundle.gz"
gzip -dc "$bundle.gz" | cmp -s - "$bundle" || die ".gz does not match the .js after rebuild"

local_md5="$(md5sum "$bundle" | awk '{print $1}')"
local_gz_md5="$(md5sum "$bundle.gz" | awk '{print $1}')"

info "Syncing Skyline bundle to all CubeCOS nodes"
cubectl node rsync "$bundle"
cubectl node rsync "$bundle.gz"

info "Comparing checksums on every node"
out="$(cubectl node exec -pn "md5sum $bundle $bundle.gz" 2>&1 || true)"
echo "$out"
bad=0
for pair in "$local_md5  $bundle" "$local_gz_md5  $bundle.gz"; do
    want="${pair%%  *}" file="${pair#*  }"
    seen="$(tr -d '\r' <<<"$out" | grep -oE "[0-9a-f]{32}  $file\$" | awk '{print $1}' | sort -u || true)"
    if [[ $seen == "$want" ]]; then
        echo "OK   $(basename "$file") identical on all reporting nodes"
    else
        echo "FAIL $(basename "$file") differs, expected $want, saw: ${seen:-nothing}" >&2
        bad=1
    fi
done
nodes="$(cubectl node list 2>/dev/null | grep -c . || true)"
reported="$(tr -d '\r' <<<"$out" | grep -cE "[0-9a-f]{32}  $bundle\$" || true)"
(( nodes == 0 || reported >= nodes )) || { echo "WARNING: $reported of $nodes nodes reported a checksum; re-check the rest." >&2; bad=1; }

plain="$(curl -sk "https://$addr/$name" | md5sum | awk '{print $1}')"
gzsrv="$(curl -sk -H 'Accept-Encoding: gzip' "https://$addr/$name" | gzip -dc 2>/dev/null | md5sum | awk '{print $1}')"
[[ $plain == "$local_md5" ]] && echo "OK   nginx serves the patched bundle (plain)" || echo "WARNING: nginx plain response differs from the patched file" >&2
[[ $gzsrv == "$local_md5" ]] && echo "OK   nginx serves the patched bundle (gzip)" || echo "WARNING: nginx gzip response differs from the patched file" >&2

cat <<EOF

Done. cube-cos-api and the Skyline console now use Keycloak user '$nuser'.
In the browser: hard-reload (static files are cached for 1 day), log out and back
in, then open Storage > Volumes and Compute > Images; the tokens call should return 200.
Backups in $BACKUP_DIR: cube-cos-api.yaml.bak, cube-cos-api.yaml.in.bak, $name.bak, $name.gz.bak
The Skyline edit is lost if the skyline package is reinstalled or upgraded.
EOF
if (( tokens_failed )); then
    echo "NOTE: the tokens endpoint rejected the credential (see WARNING above); Skyline may still show 401 until that is resolved." >&2
    exit 2
fi
(( bad == 0 )) || exit 2
