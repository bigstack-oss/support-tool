#!/usr/bin/env bash
# Create a dedicated Keycloak user for cube-cos-api, point cube-cos-api at it,
# sync the config to every node, restart the service, then patch the Skyline
# console credential with the same user (fix-skyline-401.sh).
#
# Steps:
#   1. Keycloak (https://<IP>:10443/auth, realm master): create <newuser> (or reset
#      its password if it exists) and add it to group cube-admins.
#   2. In /etc/cube/api/cube-cos-api.yaml and .yaml.in set auth.username/password.
#   3. cubectl node rsync both files; cubectl node exec -p "systemctl restart cube-cos-api".
#   4. Run fix-skyline-401.sh --apply with the same credential.
#
# Run as root on a CubeCOS node. Requires: python3, cubectl.
# Prompts for <IP>, <admin user>, <admin pass>, <new user>, <new pass>;
# or set KC_HOST, KC_USER, KC_PASS, NEW_USER, NEW_PASS.
# Options: --no-skyline  skip step 4.
set -Eeuo pipefail
export LC_ALL=C

CFG_DIR=/etc/cube/api
FILES=("$CFG_DIR/cube-cos-api.yaml" "$CFG_DIR/cube-cos-api.yaml.in")
GROUP=cube-admins
BACKUP_DIR="${BACKUP_DIR:-/root}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "STOP: $*" >&2; exit 1; }
info() { echo "==> $*"; }
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; .bak copies are in $BACKUP_DIR." >&2' ERR

run_skyline=1
case "${1:-}" in
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --no-skyline) run_skyline=0 ;;
    "") ;;
    *) die "Unknown argument: $1" ;;
esac

(( EUID == 0 )) || die "Run as root"
for tool in python3 cubectl; do command -v "$tool" >/dev/null || die "Missing command: $tool"; done
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

# group must exist before anything is changed
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

# create the user, or reuse it if it already exists
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
    print("user %s already exists (%s); resetting password" % (user, uid))
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

# prove the new credential works before touching any config file
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
info "Syncing to all CubeCOS nodes"
cubectl node rsync "${FILES[0]}"
cubectl node rsync "${FILES[1]}"

info "Restarting cube-cos-api on all nodes"
cubectl node exec -p "systemctl restart cube-cos-api"
sleep 5

# ------------------------------------------- 4. skyline console
if (( run_skyline )); then
    script="$HERE/fix-skyline-401.sh"
    [[ -f $script ]] || die "$script not found; copy it next to this script or re-run with --no-skyline."
    info "Patching the Skyline console credential"
    SKYLINE_USER=$nuser SKYLINE_PASS=$npass bash "$script" --apply
else
    echo "Skipped Skyline patch (--no-skyline)."
fi
unset npass NEW_PASS KC_ADMIN_PASSWORD

echo
echo "Done. cube-cos-api now authenticates to Keycloak as '$nuser'."
echo "Backups: $BACKUP_DIR/cube-cos-api.yaml.bak and $BACKUP_DIR/cube-cos-api.yaml.in.bak"
