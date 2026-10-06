#!/usr/bin/env bash
# Run as root on a CubeCOS node. The patched files are pushed to all other
# nodes with `cubectl node rsync`.
# Requires Bash, python3, gzip, curl, grep, awk, md5sum, cubectl (for --apply).
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: bash patch-skyline-console-credential.sh [--check|--apply] [options]

Fixes 401 on the Skyline Volumes/Images pages after the Keycloak admin
password changed. The console bundle hard-codes the credential used for the
cube-cos-api tokens call; this script rewrites it to the credential you enter.

  --check          (default) read-only: locate the bundle, show the current
                   username (never the password) and whether the .gz matches.
  --apply          prompt for username and password, validate them against
                   the cube-cos-api tokens endpoint, back up, patch the .js,
                   rebuild the .gz, cubectl node rsync both files, then
                   compare checksums on every node.

Options:
  --dc NAME        datacenter name (default: auto-discovered, local one)
  --no-sync        patch this node only; skip cubectl node rsync
  --skip-validate  do not test the credential against the tokens endpoint
  -h, --help       show this help

Environment:
  SKYLINE_STATIC_DIR  console static directory
                      (default /usr/local/lib/python3.9/site-packages/skyline_console/static)
  BACKUP_DIR          where .bak copies go (default /root)

Exit: 0 = done / healthy; 1 = stopped on error; 2 = check found nothing to fix
or a mismatch after sync.
EOF
}
die() { echo "STOP: $*" >&2; exit 1; }
info() { echo "==> $*"; }
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; restore from the .bak files in $BACKUP_DIR if needed." >&2' ERR

STATIC_DIR="${SKYLINE_STATIC_DIR:-/usr/local/lib/python3.9/site-packages/skyline_console/static}"
BACKUP_DIR="${BACKUP_DIR:-/root}"
PAIR_RE='\{username:"([^"\\]|\\.)*",password:"([^"\\]|\\.)*"\}'
mode=check dc="" sync=1 validate=1

while (( $# )); do
    case "$1" in
        --check) mode=check ;;
        --apply) mode=apply ;;
        --dc) shift; dc="${1:-}"; [[ -n $dc ]] || die "--dc needs a value" ;;
        --no-sync) sync=0 ;;
        --skip-validate) validate=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
    shift
done

(( EUID == 0 )) || die "Run as root"
for tool in python3 gzip curl grep awk md5sum; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
[[ -d $STATIC_DIR ]] || die "Static directory not found: $STATIC_DIR"

# ---- locate the bundle that holds the hard-coded pair -----------------------
bundle=""
find_bundle() {
    local f
    local -a hits=()
    for f in "$STATIC_DIR"/*.js; do
        if grep -qE "$PAIR_RE" "$f" && grep -q 'datacenters' "$f" && grep -q 'tokens' "$f"; then
            hits+=("$f")
        fi
    done
    (( ${#hits[@]} == 1 )) || {
        printf 'Found %d candidate bundle(s) in %s:\n' "${#hits[@]}" "$STATIC_DIR" >&2
        printf '  %s\n' "${hits[@]}" >&2
        return 2
    }
    bundle="${hits[0]}"
}
find_bundle || die "Expected exactly one bundle with a hard-coded credential pair; review the list above."
name="$(basename "$bundle")"

current_user() {
    grep -oE "$PAIR_RE" "$bundle" | head -1 | sed -E 's/^\{username:"(.*)",password:".*"\}$/\1/'
}

gz_matches() { [[ -f $bundle.gz ]] && gzip -dc "$bundle.gz" | cmp -s - "$bundle"; }

# ---- find where the console is served ---------------------------------------
addr="$(grep -ohE 'listen +[0-9.]+:9999' /etc/nginx/nginx.conf 2>/dev/null | head -1 | awk '{print $2}' || true)"

discover_dc() {
    [[ -n $dc ]] && return 0
    [[ -n $addr ]] || die "Cannot find the console listen address in /etc/nginx/nginx.conf; pass --dc and --skip-validate."
    dc="$(curl -sk "https://$addr/cos-api/v1/datacenters" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data") or []
loc = [x for x in d if x.get("isLocal")] or d
print(loc[0]["name"] if loc else "")
' 2>/dev/null || true)"
    [[ -n $dc ]] || die "Could not discover the datacenter name; pass --dc NAME."
}

info "Bundle: $bundle"
echo "Current hard-coded username: $(current_user) (password not shown)"
if gz_matches; then echo "Pre-compressed .gz matches the .js"; else echo "WARNING: .gz is missing or differs from the .js (nginx serves it to gzip clients)"; fi

if [[ $mode == check ]]; then
    echo "Check only. Re-run with --apply to patch."
    exit 0
fi

# ---- collect the credential --------------------------------------------------
[[ -t 0 ]] || die "--apply needs an interactive terminal to read the credential."
read -r -p "Username [admin]: " user
user="${user:-admin}"
read -rs -p "Password: " pass; echo
read -rs -p "Confirm password: " pass2; echo
[[ -n $pass ]] || die "Empty password"
[[ $pass == "$pass2" ]] || die "Passwords do not match"
unset pass2

# ---- validate before touching any file --------------------------------------
if (( validate )); then
    discover_dc
    info "Validating credential against cube-cos-api (datacenter $dc)"
    code="$(NEW_USER="$user" NEW_PASS="$pass" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"name": os.environ["NEW_USER"], "password": os.environ["NEW_PASS"]}))
' | curl -sk -o /dev/null -w '%{http_code}' -X POST \
        "https://$addr/cos-api/v1/datacenters/$dc/tokens" \
        -H 'Content-Type: application/json' --data-binary @-)"
    [[ $code == 200 || $code == 201 ]] || die "tokens endpoint returned $code for that credential; nothing was changed. Check the Keycloak admin password."
    echo "Credential accepted ($code)"
fi

# ---- back up, patch, rebuild gz ---------------------------------------------
info "Backing up to $BACKUP_DIR (existing .bak files are kept)"
cp -an "$bundle" "$BACKUP_DIR/$name.bak"
[[ -f $bundle.gz ]] && cp -an "$bundle.gz" "$BACKUP_DIR/$name.gz.bak"

info "Patching $name"
NEW_USER="$user" NEW_PASS="$pass" python3 - "$bundle" <<'PY'
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
unset pass

info "Rebuilding $name.gz"
gzip -9 -n -c "$bundle" > "$bundle.gz.new"
if [[ -f $bundle.gz ]]; then
    chmod --reference="$bundle.gz" "$bundle.gz.new"
    chown --reference="$bundle.gz" "$bundle.gz.new"
else
    chmod --reference="$bundle" "$bundle.gz.new"
fi
mv -f "$bundle.gz.new" "$bundle.gz"
gz_matches || die ".gz does not match the .js after rebuild"

# ---- sync to all nodes -------------------------------------------------------
local_md5="$(md5sum "$bundle" | awk '{print $1}')"
local_gz_md5="$(md5sum "$bundle.gz" | awk '{print $1}')"
if (( sync )); then
    command -v cubectl >/dev/null || die "cubectl not found; patched this node only. Re-run on a node with cubectl or copy the files by hand."
    info "Syncing to all CubeCOS nodes"
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
    (( bad == 0 )) || exit 2
else
    echo "Skipped sync (--no-sync). Other nodes still serve the old bundle."
fi

# ---- confirm what nginx serves ----------------------------------------------
if [[ -n $addr ]]; then
    plain="$(curl -sk "https://$addr/$name" | md5sum | awk '{print $1}')"
    gzsrv="$(curl -sk -H 'Accept-Encoding: gzip' "https://$addr/$name" | gzip -dc 2>/dev/null | md5sum | awk '{print $1}')"
    [[ $plain == "$local_md5" ]] && echo "OK   nginx serves the patched bundle (plain)" || echo "WARNING: nginx plain response differs from the patched file" >&2
    [[ $gzsrv == "$local_md5" ]] && echo "OK   nginx serves the patched bundle (gzip)" || echo "WARNING: nginx gzip response differs from the patched file" >&2
fi

cat <<EOF

Done. In the browser: hard-reload (static files are cached for 1 day), log out and
back in, then open Storage > Volumes and Compute > Images; the tokens call should
return 200.
Backups: $BACKUP_DIR/$name.bak and $BACKUP_DIR/$name.gz.bak
This edit is lost if the skyline package is reinstalled or upgraded.
EOF
