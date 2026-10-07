#!/usr/bin/env bash
# Apply (or repair) the FQDN and SP certificate used by Ceph Dashboard SAML SSO
# with the CubeCOS Keycloak IdP.
#
# Run as root on the node that currently hosts the ACTIVE ceph-mgr
# (`ceph dashboard sso setup saml2` reads the cert/key paths on the mgr host).
# Requires: ceph, openssl, curl, grep, awk, sed, mktemp.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: bash apply-ceph-sso-fqdn.sh --fqdn FQDN [--check|--apply] [options]

  --fqdn FQDN          Public name users browse to, and the name in the SP cert
                       and in the Keycloak client ID. Required.
  --check              Default. Read-only: validates cert/key/metadata, shows the
                       current SSO settings (redacted) and the values that
                       --apply would use. Changes nothing.
  --apply              Back up current settings, run `sso setup saml2`, verify,
                       enable, and test the endpoints.
  --cert FILE          SP certificate (default /var/www/certs/server.cert). A
                       chain is accepted: only the first (leaf) cert is used.
  --key FILE           Matching private key (default /var/www/certs/server.key).
  --port PORT          Dashboard HTTPS port behind the VIP (default 7443).
  --idp-metadata FILE  Keycloak IdP descriptor
                       (default /etc/keycloak/saml-metadata.xml).
  --username-attr NAME SAML attribute carrying the Ceph username (default username).
  --failover-mgr       After apply, if the endpoints still say "not configured"
                       and a healthy standby exists, run `ceph mgr fail`.

The IdP entity ID is read from the descriptor, never guessed: Ceph filters the
descriptor by it, and a mismatch silently saves settings with no "idp" section.
Keycloak is NOT changed. After --apply, update the Keycloak Ceph client (client ID
must equal the printed SP entity ID; import the SP certificate for signing and
encryption).

Secrets: `sso setup` echoes the private key. This script never prints raw output.
The backup file (mode 600) contains the old private key; protect or delete it.

Exit: 0 = ready / applied; 1 = stopped or error; 2 = check found problems.
EOF
}
die()  { echo "STOP: $*" >&2; exit 1; }
say()  { printf '\n=== %s ===\n' "$*"; }
redact() { sed -E 's/[A-Za-z0-9+\/=]{40,}/<redacted>/g'; }

leaf_dir=""
cleanup() { [[ -n $leaf_dir ]] && rm -rf "$leaf_dir"; return 0; }
trap cleanup EXIT
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; see the backup file if one was printed." >&2' ERR

mode=check fqdn="" cert=/var/www/certs/server.cert key=/var/www/certs/server.key
port=7443 idp_md=/etc/keycloak/saml-metadata.xml attr=username failover=0
while (( $# )); do
    case $1 in
        --check) mode=check ;;
        --apply) mode=apply ;;
        --fqdn) fqdn=${2:?--fqdn needs a value}; shift ;;
        --cert) cert=${2:?--cert needs a value}; shift ;;
        --key) key=${2:?--key needs a value}; shift ;;
        --port) port=${2:?--port needs a value}; shift ;;
        --idp-metadata) idp_md=${2:?--idp-metadata needs a value}; shift ;;
        --username-attr) attr=${2:?--username-attr needs a value}; shift ;;
        --failover-mgr) failover=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown option: $1" ;;
    esac
    shift
done
[[ -n $fqdn ]] || { usage; die '--fqdn is required.'; }
[[ $fqdn =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "Invalid FQDN: $fqdn"
[[ $port =~ ^[0-9]+$ ]] || die "Invalid port: $port"
for tool in ceph openssl curl grep awk sed mktemp; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
(( EUID == 0 )) || die 'Run as root on a controller.'

problems=0
bad()  { echo "PROBLEM: $*"; problems=$((problems + 1)); }
warn() { echo "WARN: $*"; }
ok()   { echo "OK: $*"; }

timeout 30 ceph -s >/dev/null 2>&1 || die 'ceph is not responding.'

# ---------------------------------------------------------------- 1. cluster
say "1. Ceph and mgr"
health=$(timeout 30 ceph health 2>&1 | head -1)
mgr_json=$(timeout 30 ceph mgr stat -f json 2>/dev/null || true)
active=$(grep -o '"active_name": *"[^"]*"' <<<"$mgr_json" | cut -d'"' -f4 || true)
standby=$(grep -o '"num_standby": *[0-9]*' <<<"$mgr_json" | grep -o '[0-9]*$' || true)
echo "Health: $health"
echo "Active mgr: ${active:-?}  standbys: ${standby:-?}  this host: $(hostname -s)"
[[ $health == HEALTH_OK* ]] || warn 'cluster is not HEALTH_OK.'
if [[ ${active:-} == "$(hostname -s)" ]]; then
    ok 'this host runs the active mgr.'
else
    bad 'run this on the active mgr host (cert/key paths are read there).'
fi

prefix=$(timeout 30 ceph config get mgr mgr/dashboard/url_prefix 2>/dev/null || true)
base_path=""; [[ -n $prefix ]] && base_path="/$prefix"
base_url="https://$fqdn:$port"
echo "Dashboard URL prefix: '${prefix}'"

# ------------------------------------------------------------ 2. certificate
say "2. SP certificate and key"
sp_cert=$cert
if [[ ! -r $cert ]]; then bad "cert not readable: $cert"
elif [[ ! -r $key ]]; then bad "key not readable: $key"
else
    count=$(grep -c 'BEGIN CERTIFICATE' "$cert" || true)
    echo "Certificates in file: $count"
    if (( count > 1 )); then
        warn 'file is a chain; the first (leaf) cert will be extracted and used.'
        leaf_dir=$(mktemp -d /run/ceph-sso-leaf.XXXXXX)
        chmod 755 "$leaf_dir"
        openssl x509 -in "$cert" -out "$leaf_dir/leaf.pem"
        chmod 644 "$leaf_dir/leaf.pem"
        sp_cert=$leaf_dir/leaf.pem
    fi
    openssl x509 -in "$sp_cert" -noout -subject -issuer -dates | sed 's/^/  /'
    cert_pub=$(openssl x509 -in "$sp_cert" -noout -pubkey | openssl sha256 | awk '{print $NF}')
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 | awk '{print $NF}')
    if [[ $cert_pub == "$key_pub" ]]; then ok 'key matches certificate.'
    else bad 'key does NOT match the certificate (public-key digests differ).'; fi
    if openssl x509 -in "$sp_cert" -noout -checkend 0 >/dev/null; then
        openssl x509 -in "$sp_cert" -noout -checkend 2592000 >/dev/null \
            && ok 'certificate valid for more than 30 days.' \
            || warn 'certificate expires within 30 days.'
    else
        bad 'certificate is EXPIRED.'
    fi
    if openssl x509 -in "$sp_cert" -noout -checkhost "$fqdn" 2>/dev/null | grep -q 'does match'; then
        ok "certificate covers $fqdn."
    else
        bad "certificate does not list $fqdn (CN/SAN)."
    fi
    [[ $(stat -c %a "$key") =~ [0-7][0-7][4-7]$ ]] \
        && warn "key file $key is world-readable ($(stat -c %a "$key"))."
fi

# -------------------------------------------------------------- 3. IdP data
say "3. Keycloak IdP descriptor"
idp_entity=""
if [[ ! -r $idp_md ]]; then
    bad "descriptor missing: $idp_md (see known issue: keycloak SAML metadata never retried)."
else
    idp_entity=$(grep -o 'entityID="[^"]*"' "$idp_md" | head -1 | cut -d'"' -f2)
    echo "IdP entityID (from file): $idp_entity"
    grep -o 'WantAuthnRequestsSigned="[a-z]*"' "$idp_md" | head -1 || true
    [[ -n $idp_entity ]] || bad 'no entityID found in the descriptor.'
    idp_host=$(sed -E 's#^https?://([^:/]+).*#\1#' <<<"$idp_entity")
    [[ $idp_host == "$fqdn" ]] || warn "IdP host ($idp_host) differs from --fqdn ($fqdn); fine only if intended."
fi

# ----------------------------------------------------- 4. current + planned
say "4. Current settings (redacted)"
timeout 30 ceph dashboard sso status 2>&1 || true
cur=$(timeout 30 ceph dashboard sso show saml2 2>&1 | redact || true)
grep -o -E '"(entityId|url)": "[^"]*"' <<<"$cur" | sed 's/^/  /' || true
if grep -q '"idp"' <<<"$cur"; then ok 'stored settings have an idp section.'
else warn 'stored settings have NO idp section (enable would fail).'; fi

say "5. Values --apply will use / Keycloak must match"
echo "SP base URL:       $base_url"
echo "SP entity ID:      $base_url$base_path/auth/saml2/metadata   (Keycloak Client ID)"
echo "ACS URL:           $base_url$base_path/auth/saml2             (Valid redirect URI)"
echo "Login URL:         $base_url$base_path/auth/saml2/login"
echo "IdP entity ID:     ${idp_entity:-?}"
echo "Username attr:     $attr (Keycloak mapper attribute name must match exactly)"

if [[ $mode == check ]]; then
    say "Result"
    (( problems == 0 )) && { echo 'Ready: no blocking problems. Re-run with --apply.'; exit 0; }
    echo "$problems blocking problem(s). Fix them before --apply."; exit 2
fi

# ------------------------------------------------------------------- apply
(( problems == 0 )) || die "$problems blocking problem(s) above; not applying."
say "6. Apply"
backup=/root/ceph-sso-backup-$(date +%Y%m%d-%H%M%S).json
( umask 077; timeout 30 ceph dashboard sso show saml2 >"$backup" 2>&1 || true )
echo "Backup (contains old private key, mode 600): $backup"
echo "Rollback: re-run this script with the previous --fqdn/--cert/--key."

set +e
out=$(timeout 60 ceph dashboard sso setup saml2 "$base_url" "$idp_md" "$attr" "$idp_entity" "$sp_cert" "$key" 2>&1)
rc=$?
set -e
echo "sso setup exit: $rc"
redact <<<"$out" | cut -c1-300
(( rc == 0 )) || die 'sso setup failed.'

stored=$(timeout 30 ceph dashboard sso show saml2 2>&1 | redact)
if grep -q "\"idp\": {\"entityId\": \"$idp_entity\"" <<<"$stored"; then
    ok 'idp section saved with the descriptor entityID.'
else
    die 'saved settings have no matching idp section; entityID mismatch. Not enabling.'
fi

set +e
en=$(timeout 30 ceph dashboard sso enable saml2 2>&1); en_rc=$?
set -e
echo "sso enable exit: $en_rc: $(cut -c1-200 <<<"$en")"
(( en_rc == 0 )) || die 'sso enable failed.'

sso_test() {
    local md login
    md=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "$base_url$base_path/auth/saml2/metadata" || true)
    login=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' "$base_url$base_path/auth/saml2/login" || true)
    echo "metadata HTTP $md"
    echo "login    HTTP ${login:0:160}"
    [[ $md == 200 && $login == 30[1237]* ]]
}

say "7. Endpoint test"
if ! sso_test; then
    if (( failover )) && [[ ${standby:-0} -ge 1 && $health == HEALTH_OK* ]]; then
        echo "Endpoints not ready; failing over active mgr ${active}."
        ceph mgr fail "$active"; sleep 20
        echo 'NOTE: re-run --check on the new active mgr host to confirm.'
    else
        warn 'endpoints not ready. If the FQDN does not resolve from this node, test from a client; else consider --failover-mgr.'
        exit 1
    fi
fi

say "Done"
echo "Ceph side applied. Now update Keycloak (client ID = SP entity ID above, import SP cert,"
echo "mapper attribute '$attr'), then test the login in a browser and confirm the Ceph user exists."
