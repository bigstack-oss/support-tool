#!/usr/bin/env bash
# Create Ceph dashboard users for Keycloak users so SAML SSO logins are authorized.
#
# Ceph authenticates via SAML but authorizes by a local dashboard user whose name
# equals the SAML `username` attribute. This script lists enabled Keycloak users
# and creates the missing Ceph users with one role. It never modifies or deletes
# an existing Ceph user.
#
# Run as root on a controller. Requires: ceph, python3, openssl, mktemp.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: bash sync-ceph-sso-users.sh --keycloak-url URL [--check|--apply] [options]

  --keycloak-url URL  Keycloak base incl. /auth, e.g. https://<fqdn>:10443/auth. Required.
  --check             Default. Lists what would be created. Changes nothing.
  --apply             Create the missing Ceph users.
  --role ROLE         Ceph role for new users (default read-only). Least privilege:
                      read-only | block-manager | rgw-manager | cluster-manager |
                      pool-manager | cephfs-manager | administrator ...
  --realm NAME        Keycloak realm (default master).
  --kc-admin NAME     Keycloak admin user (default admin). The password is read from
                      $KC_ADMIN_PASSWORD or prompted (never put it on the command line).
  --exclude REGEX     Skip usernames matching this extended regex
                      (default '^service-account-').
  --max N             Refuse to apply if more than N users would be created
                      (default 50) so an unexpectedly large realm is noticed.

Only enabled Keycloak users with names Ceph accepts ([A-Za-z0-9._@+-]) are used.
Each new Ceph user gets a random throwaway password; SSO never uses it.
Exit: 0 = nothing missing / applied; 1 = error; 2 = check found missing users.
EOF
}
die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: command failed at line $LINENO. Users created so far are kept." >&2' ERR

mode=check kc_url="" role=read-only realm=master kc_admin=admin exclude='^service-account-' max=50
while (( $# )); do
    case $1 in
        --check) mode=check ;;
        --apply) mode=apply ;;
        --keycloak-url) kc_url=${2:?--keycloak-url needs a value}; shift ;;
        --role) role=${2:?--role needs a value}; shift ;;
        --realm) realm=${2:?--realm needs a value}; shift ;;
        --kc-admin) kc_admin=${2:?--kc-admin needs a value}; shift ;;
        --exclude) exclude=${2:?--exclude needs a value}; shift ;;
        --max) max=${2:?--max needs a value}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown option: $1" ;;
    esac
    shift
done
[[ -n $kc_url ]] || { usage; die '--keycloak-url is required.'; }
[[ $kc_url =~ ^https://[A-Za-z0-9.:/_-]+$ ]] || die "Invalid --keycloak-url: $kc_url"
[[ $role =~ ^[a-z0-9-]+$ && $realm =~ ^[A-Za-z0-9_-]+$ && $max =~ ^[0-9]+$ ]] || die 'Invalid --role/--realm/--max.'
for tool in ceph python3 openssl mktemp; do command -v "$tool" >/dev/null || die "Missing command: $tool"; done
(( EUID == 0 )) || die 'Run as root on a controller.'

timeout 30 ceph dashboard ac-role-show "$role" >/dev/null 2>&1 || die "Ceph role not found: $role"

if [[ -z ${KC_ADMIN_PASSWORD:-} ]]; then
    read -r -s -p "Keycloak '$kc_admin' password: " KC_ADMIN_PASSWORD; echo
fi
export KC_ADMIN_PASSWORD KC_URL=$kc_url KC_REALM=$realm KC_ADMIN=$kc_admin

# Enabled Keycloak usernames, one per line. TLS verification is off: the IdP uses a
# private CA on the VIP. Credentials stay in the environment, not in argv.
kc_users=$(python3 - <<'EOF'
import json, os, ssl, sys, urllib.parse, urllib.request
ctx = ssl._create_unverified_context()
base = os.environ["KC_URL"].rstrip("/")
body = urllib.parse.urlencode({"grant_type": "password", "client_id": "admin-cli",
    "username": os.environ["KC_ADMIN"], "password": os.environ["KC_ADMIN_PASSWORD"]}).encode()
try:
    tok = json.load(urllib.request.urlopen(
        base + "/realms/master/protocol/openid-connect/token", body, 30, context=ctx))["access_token"]
except Exception as e:
    sys.exit("token request failed: %s" % e)
names, first = [], 0
while True:
    req = urllib.request.Request("%s/admin/realms/%s/users?first=%d&max=100" % (
        base, os.environ["KC_REALM"], first), headers={"Authorization": "Bearer " + tok})
    page = json.load(urllib.request.urlopen(req, timeout=30, context=ctx))
    names += [u["username"] for u in page if u.get("enabled")]
    if len(page) < 100:
        break
    first += 100
print("\n".join(sorted(set(names))))
EOF
) || die 'could not list Keycloak users (check URL, realm and admin password).'
unset KC_ADMIN_PASSWORD
[[ -n $kc_users ]] || die 'Keycloak returned no enabled users.'

ceph_users=$(timeout 30 ceph dashboard ac-user-show 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')

missing=() skipped=()
while IFS= read -r u; do
    [[ -n $u ]] || continue
    if [[ ! $u =~ ^[A-Za-z0-9._@+-]+$ ]] || grep -Eq -- "$exclude" <<<"$u"; then skipped+=("$u"); continue; fi
    grep -qxF -- "$u" <<<"$ceph_users" || missing+=("$u")
done <<<"$kc_users"

echo "Keycloak enabled users: $(wc -l <<<"$kc_users" | tr -d ' ')  Ceph users: $(wc -l <<<"$ceph_users" | tr -d ' ')"
echo "Skipped (invalid name or excluded): ${#skipped[@]}${skipped[*]:+ -> ${skipped[*]}}"
echo "Missing in Ceph, would create with role '$role': ${#missing[@]}"
printf '  %s\n' "${missing[@]}"

(( ${#missing[@]} )) || { echo 'Nothing to do.'; exit 0; }
[[ $mode == apply ]] || { echo 'Check only. Re-run with --apply to create them.'; exit 2; }
(( ${#missing[@]} <= max )) || die "${#missing[@]} users exceed --max $max; raise --max if intended."

failed=0
for u in "${missing[@]}"; do
    pw=$(mktemp); chmod 600 "$pw"; openssl rand -base64 24 >"$pw"
    if timeout 30 ceph dashboard ac-user-create "$u" -i "$pw" "$role" --force-password --enabled >/dev/null 2>&1; then
        echo "created: $u ($role)"
    else
        echo "FAILED:  $u" >&2; failed=$((failed + 1))
    fi
    rm -f "$pw"
done
(( failed == 0 )) || die "$failed user(s) could not be created."
echo 'Done. Each user can now log in via Ceph SSO; verify one login in a browser.'
