#!/usr/bin/env bash
# Interactively pick Keycloak users and add the missing ones to Ceph so they can
# log in to the dashboard through SAML SSO.
#
# Ceph authorizes by a dashboard user whose name equals the SAML `username`.
# This script never modifies or deletes an existing Ceph user.
#
# Run as root on a controller. Requires: ceph, python3, openssl, mktemp.
# Prompts for <host>, <user>, <pass>; or set KC_HOST, KC_USER, KC_PASS.
set -Eeuo pipefail
export LC_ALL=C

die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: command failed at line $LINENO. Users created so far are kept." >&2' ERR
[[ ${1:-} == -h || ${1:-} == --help ]] && {
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

for tool in ceph python3 openssl mktemp; do command -v "$tool" >/dev/null || die "Missing command: $tool"; done
(( EUID == 0 )) || die 'Run as root on a controller.'
timeout 30 ceph -s >/dev/null 2>&1 || die 'ceph is not responding.'

# ------------------------------------------------------------------ inputs
host=${KC_HOST:-}; user=${KC_USER:-}; pass=${KC_PASS:-}
[[ -n $host ]] || read -r -p 'Keycloak <host> (FQDN or VIP): ' host
[[ -n $user ]] || read -r -p 'Keycloak <user> [admin]: ' user
user=${user:-admin}
[[ -n $pass ]] || { read -r -s -p "Keycloak <pass> for '$user': " pass; echo; }
[[ $host =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "Invalid host: $host"
[[ $host == *:* ]] || host=$host:10443
export KC_URL="https://$host/auth" KC_ADMIN=$user KC_ADMIN_PASSWORD=$pass
unset pass

# ----------------------------------------------- enabled Keycloak users
# TLS verification is off: the IdP uses a private CA. Credentials stay in the
# environment, not in argv.
if ! kc_users=$(python3 - <<'EOF'
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
    req = urllib.request.Request("%s/admin/realms/master/users?first=%d&max=100" % (base, first),
                                 headers={"Authorization": "Bearer " + tok})
    page = json.load(urllib.request.urlopen(req, timeout=30, context=ctx))
    names += [u["username"] for u in page if u.get("enabled")]
    if len(page) < 100:
        break
    first += 100
print("\n".join(sorted(set(names))))
EOF
) ; then
    die 'could not list Keycloak users (check host, user and password).'
fi
unset KC_ADMIN_PASSWORD

ceph_users=$(timeout 30 ceph dashboard ac-user-show 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')

# Skip service accounts and names Ceph would reject.
users=()
while IFS= read -r u; do
    [[ $u =~ ^[A-Za-z0-9._@+-]+$ && ! $u =~ ^service-account- ]] && users+=("$u")
done <<<"$kc_users"
(( ${#users[@]} )) || die 'no enabled Keycloak users found.'

# -------------------------------------------------------------- selection
echo; echo 'Enabled Keycloak users:'
for i in "${!users[@]}"; do
    mark=""; grep -qxF -- "${users[i]}" <<<"$ceph_users" && mark='  (already in Ceph)'
    printf '%3d. %s%s\n' $((i + 1)) "${users[i]}" "$mark"
done
all=$(( ${#users[@]} + 1 ))
printf '%3d. ALL\n' "$all"

read -r -p 'Select users (numbers separated by space or comma): ' sel
selected=()
for n in ${sel//,/ }; do
    [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= all )) || die "Invalid selection: $n"
    if (( n == all )); then selected=("${users[@]}"); break; fi
    selected+=("${users[n-1]}")
done
(( ${#selected[@]} )) || die 'nothing selected.'

echo; echo 'Role:'; echo '  1. admin      (Ceph "administrator": full access)'; echo '  2. read-only'
read -r -p 'Choose role [2]: ' r
case ${r:-2} in 1) role=administrator ;; 2) role=read-only ;; *) die "Invalid role choice: $r" ;; esac

# -------------------------------------------------------- compare with Ceph
missing=() present=()
for u in $(printf '%s\n' "${selected[@]}" | sort -u); do
    if grep -qxF -- "$u" <<<"$ceph_users"; then present+=("$u"); else missing+=("$u"); fi
done
echo
echo "Already in Ceph (left unchanged): ${#present[@]}${present[*]:+ -> ${present[*]}}"
echo "To create with role '$role':      ${#missing[@]}${missing[*]:+ -> ${missing[*]}}"
(( ${#missing[@]} )) || { echo 'Nothing to add.'; exit 0; }
read -r -p 'Create these Ceph users now? [y/N]: ' ok
[[ $ok == y || $ok == Y ]] || { echo 'Aborted; nothing changed.'; exit 0; }

# ------------------------------------------------------------------ create
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
echo 'Done. The password of each new Ceph user is random and unused; they log in through Keycloak SSO.'
