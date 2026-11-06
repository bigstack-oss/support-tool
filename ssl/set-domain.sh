#!/usr/bin/env bash
# set-domain.sh - move the user-facing name of a CubeCOS 3.1.x HA cluster from the VIP
# to a public FQDN: TLS on every user port, SAML on every SP, and matching Keycloak clients.
#
# Run as root on any control node. Needs root ssh to the other control nodes (as the
# platform already has) and fix-ceph-sso-fqdn.sh in the same directory as this script.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage:
  set-domain.sh DOMAIN -c CERT_DIR             # check only (default)
  set-domain.sh DOMAIN -c CERT_DIR --apply [-y] [--fqdn-only]
  set-domain.sh DOMAIN -c CERT_DIR --verify    # domain check only (e.g. after an SSL renewal)
  set-domain.sh --rollback BACKUP_DIR [-y]

  DOMAIN        Public name, already resolving to the VIP on every control node.
  -c CERT_DIR   Directory holding the RSA certificate for DOMAIN, its chain and its key,
                in any layout (fullchain.pem + privkey.pem, DOMAIN.pem + DOMAIN.key, one
                combined file, ...). Other domains' files in the same directory are ignored.
                server.cert (leaf + intermediates), server.key and server.pem (cert + key)
                are built from it automatically.
  --check       Default. Preflight only: validate everything and print the plan. Changes nothing.
  --apply       Make the changes (after the same preflight).
  --verify      Read-only domain check, the same one --apply ends with: through DNS on
                443 5443 9999 6080 7443 8005 10443, the served chain must equal server.cert
                built from CERT_DIR, verify against the system CA bundle for DOMAIN, and
                answer HTTP; plus every SAML entityID, Skyline SSO, Rancher, Ceph.
  -y            With --apply / --rollback: do not ask for confirmation.
  --fqdn-only   Keycloak: for clusters whose SAML clients were already renamed to DOMAIN by
                hand -- keep those clients, only update their certificate; never create,
                rename or touch any https://VIP:... client.
  --rollback    Undo a run, using the backup directory it printed.

With --apply it runs the preflight, shows the plan, asks you to type YES, then:
  1. backs up every file / object it touches   -> /root/set-domain-backup/DOMAIN-TIME/
  2. Keycloak: adds FQDN copies of the 4 SAML clients (api, ceph, keystone, rancher);
     the platform's IP clients are left alone
  3. Keystone: adds the FQDN issuer to the cube_idp remote IDs
  4. k3s: TLS secret + host ingresses for DOMAIN on 10443 (Keycloak, Rancher), by SNI;
     IP access keeps the old default certificate, so downstream agents are untouched
  5. every control node, one at a time: /var/www/certs, nova's copy, IdP metadata,
     mellon SP metadata, 5443 (httpd) + 9999 (nginx) pinned to the full-chain server.cert,
     cube-cos-api domainName, Skyline keystone_url (https :5443),
     Horizon WEBSSO_KEYSTONE_URL, keystone trusted_dashboard, noVNC base URL,
     Grafana root URL; then reloads/restarts those services and checks them
     (nova-compute only where it runs: pure control nodes have none)
  5b. every compute node (cubectl node list): nova.d/90-fqdn.conf noVNC URL, restart nova-compute
  6. Ceph: dashboard + restful (8005) certificates incl. per-mgr overrides, Grafana URL, SSO via fix-ceph-sso-fqdn.sh
  7. Rancher: keycloak authconfig (rancherApiHost + IdP metadata), rolling restart
  8. domain check (as --verify): chain, trust and HTTP via DNS on every port, every SAML entityID

Not changed: Rancher server-url / cacerts (downstream agents and CMP use the IP),
OpenStack endpoint catalog, haproxy-ha, internal service URLs.

Exit: 0 = done / ready; 1 = stopped or error; 2 = --check found problems / --verify found warnings.
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CEPH_SSO=$SCRIPT_DIR/fix-ceph-sso-fqdn.sh
CA_BUNDLE=${CA_BUNDLE:-/etc/pki/tls/certs/ca-bundle.crt}
KC_PASS_FILE=/etc/cube/cos/terraform/values/keycloak-admin-password.tfvars
TF_STATE=/var/lib/terraform/terraform.tfstate
IDP=cube_idp
STAGE=/root/.set-domain-stage
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

# Path part of the four SAML SP entity IDs (= Keycloak client IDs); host part is the VIP today.
KC_CLIENTS=("443/saml/metadata" "7443/ceph/auth/saml2/metadata" "5443/v3/mellon/metadata" "10443/v1-saml/keycloak/saml/metadata")
# SPs that sign/encrypt with /var/www/certs/server.cert (cube-cos-api, ceph dashboard).
KC_CERT_CLIENTS=" 443/saml/metadata 7443/ceph/auth/saml2/metadata "

# Every node file this script may write; backed up before, restored on rollback.
NODE_FILES=(
    /var/www/certs/server.cert /var/www/certs/server.key /var/www/certs/server.pem
    /var/lib/nova/certs/server.pem
    /etc/keycloak/saml-metadata.xml
    /etc/httpd/federation/v3.xml
    /etc/httpd/conf.d/keystone-wsgi.conf /etc/httpd/conf.d/keystone-wsgi.conf.in
    /etc/cube/api/cube-cos-api.yaml /etc/cube/api/cube-cos-api.yaml.in
    /etc/skyline/skyline.yaml /etc/skyline/skyline.yaml.in
    /etc/openstack-dashboard/local_settings /etc/openstack-dashboard/local_settings.in
    /etc/keystone/keystone.conf.d /etc/keystone/keystone.conf.d/90-fqdn.conf
    /etc/nova/nova.d/90-fqdn.conf
    /etc/systemd/system/grafana-server.service.d/90-fqdn.conf
    /etc/nginx/nginx.conf /etc/nginx/nginx.conf.in
)
# Compute nodes (non-control, nova-compute running): nova-compute there builds the noVNC console URL.
COMPUTE_FILES=(/etc/nova/nova.d/90-fqdn.conf)
COMPUTES=()

PROBLEMS=0 WARNS=0 YES=0 MODE=check STEP="" FQDN_ONLY=0
ok()   { echo "✅ $*"; }
warn() { echo "⚠️ $*"; WARNS=$((WARNS + 1)); }
bad()  { echo "❌ $*"; PROBLEMS=$((PROBLEMS + 1)); }
die()  { echo "STOP: $*" >&2; exit 1; }
say()  { STEP=$*; printf '\n=== %s ===\n' "$*"; }

# ------------------------------------------------------------------ remote helpers
run() {  # run NODE "command"  (no stdin)
    local n=$1; shift
    if [[ $n == "$SELF" ]]; then bash -c "$*"; else ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "root@$n" "$*"; fi
}
pipe_to() {  # pipe_to NODE "command" < input
    local n=$1; shift
    if [[ $n == "$SELF" ]]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "root@$n" "$*"; fi
}
on() {  # SCRIPT | on NODE args...   (runs a bash script read from stdin)
    local n=$1; shift
    if [[ $n == "$SELF" ]]; then bash -s -- "$@"; else ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "root@$n" bash -s -- "$@"; fi
}
tls_fp() {  # tls_fp HOST PORT -> sha256 fingerprint served for SNI=DOMAIN
    { echo | timeout 10 openssl s_client -connect "$1:$2" -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; } || true
}
os() { ( set +u; source /etc/admin-openrc.sh; openstack "$@" ); }
tune() { ( set +u; source hex_tuning /etc/settings.txt "$1" >/dev/null 2>&1; v="T_${1//./_}"; echo "${!v:-}" ); }
mark()  { echo "$1" >> "$BK/steps"; }
begun() { grep -qx "$1" "$BK/steps" 2>/dev/null; }
node_ip() { local i; for i in "${!HOSTS[@]}"; do [[ ${HOSTS[$i]} == "$1" ]] && { echo "${NODES[$i]}"; return 0; }; done; return 1; }

# ------------------------------------------------------------------ certificates
subj()   { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//'; }
issuer() { openssl x509 -in "$1" -noout -issuer -nameopt RFC2253 | sed 's/^issuer= *//'; }
pubhash() {  # pubhash cert|key FILE
    if [[ $1 == cert ]]; then openssl x509 -in "$2" -noout -pubkey 2>/dev/null
    else openssl pkey -in "$2" -pubout -passin pass: 2>/dev/null; fi | openssl sha256 | awk '{print $NF}'
}
split_pem() {  # split_pem FILE DIR -> DIR/001.pem, 002.pem, ... one certificate each, in file order
    mkdir -p "$2"
    awk -v p="$2/" '/-----BEGIN CERTIFICATE-----/{i++; o=sprintf("%s%03d.pem", p, i)} o{print > o} /-----END CERTIFICATE-----/{close(o); o=""}' "$1"
}
chain_fps() {  # chain_fps FILE -> sha256 fingerprint of each certificate in FILE, one per line, in order
    local d c
    d=$(mktemp -d)
    split_pem "$1" "$d"
    for c in "$d"/*.pem; do
        if [[ -e $c ]]; then openssl x509 -in "$c" -noout -fingerprint -sha256 | cut -d= -f2; fi
    done
    rm -rf "$d"
}

# build_certs DOMAIN DIR OUT: find DOMAIN's leaf and its key in DIR, order the chain and write
# OUT/leaf.pem, OUT/server.cert (leaf + intermediates, no self-signed root),
# OUT/server.key and OUT/server.pem (server.cert + server.key, the order haproxy expects).
build_certs() {
    local domain=$1 dir=$2 out=$3 f c n=0 leaf="" key="" lpub cur iss next fp
    [[ -d $dir ]] || die "cert dir not found: $dir"
    rm -rf "$out/pool"; mkdir -p "$out/pool"
    for f in "$dir"/*; do
        [[ -f $f ]] || continue
        grep -q -- '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null || continue
        awk -v p="$out/pool/$n-" '/-----BEGIN CERTIFICATE-----/{i++; o=p i ".tmp"} o{print > o} /-----END CERTIFICATE-----/{close(o); o=""}' "$f"
        n=$((n + 1))
    done
    for c in "$out"/pool/*.tmp; do  # de-duplicate by fingerprint
        [[ -f $c ]] || continue
        fp=$(openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d :) || fp=""
        if [[ -n $fp ]]; then mv -f "$c" "$out/pool/$fp.pem"; else rm -f "$c"; fi
    done
    for c in "$out"/pool/*.pem; do
        [[ -f $c ]] || continue
        if ! openssl x509 -in "$c" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'; then continue; fi
        if openssl x509 -in "$c" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then continue; fi
        lpub=$(pubhash cert "$c")
        for f in "$dir"/*; do
            [[ -f $f ]] || continue
            grep -q -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" 2>/dev/null || continue
            [[ $(pubhash key "$f") == "$lpub" ]] || continue
            if [[ -n $leaf && $leaf != "$c" ]]; then
                die "more than one certificate for $domain with a matching key in $dir; keep only one"
            fi
            leaf=$c key=$f
        done
    done
    [[ -n $leaf ]] || die "no certificate for $domain with a matching private key in $dir (encrypted keys are not supported)"

    cp "$leaf" "$out/leaf.pem"; cp "$leaf" "$out/server.cert"
    cur=$leaf
    for _ in 1 2 3 4 5; do
        iss=$(issuer "$cur")
        [[ $iss == "$(subj "$cur")" ]] && break
        next=""
        for c in "$out"/pool/*.pem; do
            if [[ $c != "$cur" && $(subj "$c") == "$iss" ]]; then next=$c; break; fi
        done
        [[ -n $next ]] || break
        [[ $(subj "$next") == "$(issuer "$next")" ]] && break  # self-signed root: clients have it
        cat "$next" >> "$out/server.cert"; cur=$next
    done
    openssl pkey -in "$key" -out "$out/server.key" -passin pass: 2>/dev/null || die "cannot read key $key"
    cat "$out/server.cert" "$out/server.key" > "$out/server.pem"
    chmod 600 "$out/server.key" "$out/server.pem"
    rm -rf "$out/pool"
    echo "key: $key"
    echo "server.cert: $(grep -c 'BEGIN CERTIFICATE' "$out/server.cert") certificate(s) (leaf + intermediates)"
}

check_certs() {
    local leaf=$WORK/leaf.pem
    openssl x509 -in "$leaf" -noout -subject -issuer -enddate -ext subjectAltName | sed 's/^/  /'
    if openssl x509 -in "$leaf" -noout -text | grep -q 'Public Key Algorithm: rsaEncryption'; then ok 'RSA key.'
    else bad 'key is not RSA: Keycloak SAML signing/encryption for cube-cos-api and Ceph needs RSA.'; fi
    if ! openssl x509 -in "$leaf" -noout -checkend 604800 >/dev/null; then bad 'certificate expires within 7 days.'
    elif ! openssl x509 -in "$leaf" -noout -checkend 2592000 >/dev/null; then warn 'certificate expires within 30 days.'
    else ok 'certificate valid for more than 30 days.'; fi
    if [[ -r $CA_BUNDLE ]]; then
        if openssl verify -CAfile "$CA_BUNDLE" -untrusted "$WORK/server.cert" "$leaf" >/dev/null 2>&1; then
            ok "chain verifies against $CA_BUNDLE."
        else
            bad "chain does not verify against $CA_BUNDLE (intermediate missing from $CERT_DIR?)."
        fi
    fi
}

# ------------------------------------------------------------------ keycloak
kc_init() {
    [[ -r $KC_PASS_FILE ]] || die "missing $KC_PASS_FILE"
    ( umask 077; sed -nE 's/^[[:space:]]*keycloak_admin_password[[:space:]]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' \
        "$KC_PASS_FILE" | tr -d '\n' > "$WORK/kc.pw" )
    [[ -s $WORK/kc.pw ]] || die "no keycloak_admin_password in $KC_PASS_FILE"
    # Pin what VIP:10443 serves without SNI: the ingress default cert (self-signed, SAN = VIP).
    # This script never changes that secret, so the pin holds through apply and rollback.
    KC=https://$VIP:10443/auth KC_CA=$WORK/kc-ca.pem
    kubectl -n ingress-nginx get secret tls-private -o jsonpath='{.data.tls\.crt}' | base64 -d > "$KC_CA" || true
    curl -s --fail --max-time 20 --cacert "$KC_CA" -o /dev/null "$KC/realms/master" && return 0
    # Hand-made setups replaced that default cert: go through DOMAIN, verified by the system CAs.
    KC=https://$DOMAIN:10443/auth KC_CA=$CA_BUNDLE
    curl -s --fail --max-time 20 --cacert "$KC_CA" -o /dev/null "$KC/realms/master" \
        || die "cannot reach Keycloak with verified TLS: not at https://$VIP:10443 (ingress-nginx/tls-private), not at $KC ($CA_BUNDLE)"
    echo "  Keycloak via $KC (the VIP's default ingress certificate is not the platform's)"
}
kc() {  # kc METHOD PATH [curl args] -> response body
    local m=$1 p=$2 tok; shift 2
    tok=$(curl -s --fail --cacert "$KC_CA" -d client_id=admin-cli -d username=admin --data-urlencode "password@$WORK/kc.pw" \
        -d grant_type=password "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token) || tok=""
    [[ -n $tok && $tok != null ]] || { echo "Keycloak admin login failed ($KC)" >&2; return 1; }
    curl -s --fail-with-body --cacert "$KC_CA" -X "$m" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
        "$KC/admin/realms/master$p" "$@"
}
kc_find() { kc GET /clients -G --data-urlencode "clientId=$1" | jq -c '.[0] // empty'; }
tf_client_uuid() {  # tf_client_uuid SUFFIX -> UUID of the client terraform created as https://VIP:SUFFIX
    [[ -r $TF_STATE ]] || return 0
    jq -r --arg c "https://$VIP:$1" '.resources[]? | select(.type == "keycloak_saml_client")
        | .instances[]?.attributes | select(.client_id == $c) | .id' "$TF_STATE" | head -1
}

# ------------------------------------------------------------------ preflight
node_check() {
    cat <<'EOS'
D=$1; shift; rc=0
for f in "$@"; do [ -e "$f" ] || { echo "missing $f"; rc=1; }; done
for f in /etc/cube/api/cube-cos-api.yaml /etc/cube/api/cube-cos-api.yaml.in; do
    grep -q '^  listen:$' "$f" 2>/dev/null || { echo "no 'listen:' block in $f"; rc=1; }; done
for f in /etc/skyline/skyline.yaml /etc/skyline/skyline.yaml.in; do
    grep -q '^  keystone_url:' "$f" 2>/dev/null || { echo "no keystone_url in $f"; rc=1; }; done
for u in haproxy nginx httpd skyline-apiserver openstack-nova-novncproxy grafana-server cube-cos-api; do
    systemctl is-active -q "$u" || { echo "service $u is not active"; rc=1; }; done
echo "dns $(getent ahostsv4 "$D" | awk 'NR==1{print $1}')"
# what 5443 / 9999 load today (apply pins both to /var/www/certs/server.cert = leaf + chain)
c5443=$(sed -n '/^<VirtualHost \*:5443>/,/^<\/VirtualHost>/s/^[[:space:]]*SSLCertificate\(Chain\)\{0,1\}File[[:space:]]*//p' \
    /etc/httpd/conf.d/keystone-wsgi.conf | tr '\n' ' ')
c9999=$(sed -n 's/^[[:space:]]*ssl_certificate[[:space:]]\{1,\}\([^;]*\);.*/\1/p' /etc/nginx/nginx.conf | sort -u | tr '\n' ' ')
echo "info server.cert has $(grep -c 'BEGIN CERTIFICATE' /var/www/certs/server.cert 2>/dev/null || echo 0) cert(s), server.pem $(grep -c 'BEGIN CERTIFICATE' /var/www/certs/server.pem 2>/dev/null || echo 0); 5443 loads: ${c5443:-?}; 9999 loads: ${c9999:-?}"
exit $rc
EOS
}

preflight() {
    local n out ip suf rep eid cur
    say "1. Cluster and nodes"
    echo "VIP: $VIP   control nodes: ${NODES[*]}   this node: $SELF"
    for n in "${NODES[@]}"; do
        out=$(node_check | on "$n" "$DOMAIN" /var/www/certs/server.cert /var/www/certs/server.key \
            /var/www/certs/server.pem /etc/keycloak/saml-metadata.xml /etc/httpd/federation/v3.xml \
            /etc/nova/nova.d 2>&1) || bad "node $n: $(grep -vE '^(dns|info) ' <<<"$out" | tr '\n' ';')"
        sed -n "s/^info /  $n now: /p" <<<"$out"
        ip=$(sed -n 's/^dns //p' <<<"$out")
        if [[ $ip == "$VIP" ]]; then ok "node $n resolves $DOMAIN to the VIP."
        else bad "node $n resolves $DOMAIN to '${ip:-nothing}', not $VIP (cube-cos-api crash-loops without it)."; fi
    done

    say "1b. Compute nodes (noVNC console URL)"
    local h a r st
    COMPUTES=()
    while IFS=, read -r h a r; do
        [[ -n $a && " ${NODES[*]} " != *" $a "* ]] || continue
        if ! st=$(run "$a" 'echo "$(systemctl is-active openstack-nova-compute) $([ -d /etc/nova/nova.d ] && echo nova.d)"'); then
            bad "compute $h ($a): cannot ssh as root"; continue
        fi
        if [[ $st == "active nova.d" ]]; then COMPUTES+=("$a"); ok "compute $h ($a): nova-compute active, reads /etc/nova/nova.d"
        elif [[ $st == active* ]]; then bad "compute $h ($a): nova-compute active but no /etc/nova/nova.d"
        else echo "  $h ($a, $r): no nova-compute running, skipped"; fi
    done < <(cubectl node list 2>/dev/null || true)
    (( ${#COMPUTES[@]} )) || echo "  no separate compute nodes"

    say "2. Certificate from $CERT_DIR"
    build_certs "$DOMAIN" "$CERT_DIR" "$WORK"
    check_certs

    say "3. Keycloak"
    kc_init
    for suf in "${KC_CLIENTS[@]}"; do
        rep=$(kc_find "https://$VIP:$suf") || rep=""
        cur=$(kc_find "https://$DOMAIN:$suf") || cur=""
        if (( FQDN_ONLY )) && [[ -n $cur ]]; then
            ok "client https://$DOMAIN:$suf (--fqdn-only: kept, certificate updated; IP client untouched)"
        elif [[ -n $rep ]]; then
            ok "client https://$VIP:$suf"
            [[ -z $cur ]] || echo "  note: https://$DOMAIN:$suf already exists; it will be updated."
        elif [[ -z $cur ]]; then
            bad "Keycloak client https://$VIP:$suf not found (nor https://$DOMAIN:$suf)"
        elif [[ $(jq -r .id <<<"$cur") == "$(tf_client_uuid "$suf")" ]]; then
            warn "https://$VIP:$suf was renamed by hand to https://$DOMAIN:$suf (terraform's object): apply renames it back and adds the FQDN client as a separate copy (or use --fqdn-only to keep it)"
        else
            warn "https://$VIP:$suf is missing; https://$DOMAIN:$suf is not terraform's object: apply recreates the IP client as a copy (terraform state still names the old UUID $(tf_client_uuid "$suf"))"
        fi
    done
    eid=https://$DOMAIN:10443/auth/realms/master
    # TLS verified against the pinned VIP cert; Host header makes Keycloak issue the FQDN entityID.
    # This descriptor carries the IdP signing cert every SP will trust, so never fetch it with -k.
    if curl -s --fail --max-time 20 --cacert "$KC_CA" -H "Host: $DOMAIN:10443" -o "$WORK/idp-metadata.xml" \
        "$KC/realms/master/protocol/saml/descriptor"; then
        cur=$(grep -o 'entityID="[^"]*"' "$WORK/idp-metadata.xml" | head -1 | cut -d'"' -f2) || cur=""
        if [[ $cur == "$eid" ]]; then ok "IdP descriptor entityID $cur"; else bad "IdP descriptor entityID '$cur', expected $eid"; fi
    else
        bad "cannot fetch the Keycloak descriptor for $DOMAIN"
    fi

    say "4. Keystone"
    cur=$(os identity provider show "$IDP" -f json 2>/dev/null | jq -c .remote_ids) || cur=""
    if [[ -n $cur ]]; then ok "$IDP remote_ids $cur"; else bad "cannot read identity provider $IDP"; fi

    say "5. Ceph"
    cur=$(timeout 30 ceph health 2>&1 | head -1) || cur=""
    [[ $cur == HEALTH_OK* ]] && ok "ceph $cur" || warn "ceph: $cur"
    cur=$(ceph mgr stat -f json 2>/dev/null | jq -r .active_name) || cur=""
    if node_ip "$cur" >/dev/null; then ok "active mgr $cur ($(node_ip "$cur"))"; else bad "active mgr '$cur' is not a control node"; fi
    [[ -r $CEPH_SSO ]] && ok "found $CEPH_SSO" || bad "missing $CEPH_SSO (copy it next to this script)"
    cur=$(ceph_local_keys | tr '\n' ' ') || cur=""
    [[ -z $cur ]] || echo "  per-mgr cert overrides (apply overwrites them too): $cur"

    say "6. Rancher / k3s"
    cur=$(kubectl get authconfigs.management.cattle.io keycloak -o jsonpath='{.enabled} {.rancherApiHost}' 2>/dev/null) || cur=""
    [[ $cur == true* ]] && ok "keycloak authconfig: $cur" || bad "keycloak authconfig not enabled: '$cur'"
    for cur in cattle-system/rancher keycloak/keycloak; do
        kubectl -n "${cur%/*}" get ingress "${cur#*/}" >/dev/null 2>&1 && ok "ingress $cur" || bad "ingress $cur not found"
    done
    # hand-made FQDN setups already have ingresses for DOMAIN; ours would duplicate the host rules
    cur=$(kubectl get ingress -A -o json 2>/dev/null | jq -r --arg h "$DOMAIN" '.items[]
        | select(.metadata.labels["app.kubernetes.io/managed-by"] != "set-domain.sh")
        | select(any(.spec.rules[]?; .host == $h)) | "\(.metadata.namespace)/\(.metadata.name)"' | tr '\n' ' ') || cur=""
    [[ -z $cur ]] || warn "ingresses not made by this script already use host $DOMAIN: $cur-- apply adds rancher-fqdn/keycloak-fqdn for the same host; delete those old ones afterwards (back them up with kubectl get -o yaml)"
    echo "server-url (unchanged): $(kubectl get settings.management.cattle.io server-url -o jsonpath='{.value}' 2>/dev/null || true)"
    kubectl get clusters.management.cattle.io -o custom-columns='CLUSTER:.spec.displayName,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null || true
}

plan() {
    say "Plan for $DOMAIN"
    local kcplan="add clients https://$DOMAIN:{443,7443,5443,10443}/... (copies of the VIP clients; api+ceph get the new cert)"
    (( ! FQDN_ONLY )) || kcplan="--fqdn-only: keep the https://$DOMAIN:... clients, api+ceph get the new cert; IP clients untouched"
    cat <<EOF
Keycloak   $kcplan
Keystone   $IDP remote_ids += https://$DOMAIN:10443/auth/realms/master
k3s        secret $SECRET + ingresses rancher-fqdn / keycloak-fqdn (host $DOMAIN, 10443)
Nodes      ${NODES[*]} (this node last), per node:
             /var/www/certs/server.{cert,key,pem}, /var/lib/nova/certs/server.pem
             /etc/keycloak/saml-metadata.xml       <- descriptor with issuer https://$DOMAIN:10443/auth/realms/master
             /etc/httpd/federation/v3.xml          mellon SP -> https://$DOMAIN:5443/v3/mellon/...
             keystone-wsgi.conf(.in)               fix 3.1.0 typo "WSGIProcessGroup keystone-ssl;" (5443 API was 500);
                                                   5443 vhost -> /var/www/certs/server.{cert,key}, no SSLCertificateChainFile
             nginx.conf(.in)                       ssl_certificate(_key) -> /var/www/certs/server.{cert,key} (9999)
             cube-cos-api.yaml(.in)                spec.listen.domainName: $DOMAIN
             skyline.yaml(.in)                     keystone_url: https://$DOMAIN:5443/v3/
             local_settings(.in)                   WEBSSO_KEYSTONE_URL = "https://$DOMAIN:5443/v3"
             keystone.conf.d/90-fqdn.conf          trusted_dashboard += https://$DOMAIN{/horizon,:9999/...}
             nova.d/90-fqdn.conf                   novncproxy_base_url = https://$DOMAIN:6080/vnc_auto.html
             grafana drop-in                       GF_SERVER_ROOT_URL=https://$DOMAIN/grafana
             reload haproxy nginx httpd; restart skyline-apiserver nova-novncproxy grafana-server cube-cos-api (+ nova-compute, openstack-keystone where running)
Computes   ${COMPUTES[*]:-none}: nova.d/90-fqdn.conf novncproxy_base_url = https://$DOMAIN:6080/vnc_auto.html; restart nova-compute
Ceph       dashboard + restful cert (global + any per-mgr override, 8005), GRAFANA_API_URL https://$DOMAIN/grafana, SSO base https://$DOMAIN:7443
Rancher    authconfig keycloak: rancherApiHost https://$DOMAIN:10443 + new IdP metadata; rolling restart
Backup     $BK
EOF
}

confirm() {
    (( YES )) && return 0
    [[ -t 0 ]] || die "no terminal to confirm on; pass -y"
    local a
    read -r -p "$1 Type 'YES' to continue: " a
    [[ $a == YES ]] || die "not confirmed; nothing changed by this step."
}

# ------------------------------------------------------------------ backup
backup_node() {  # backup_node NODE FILE...: tarball of the files that exist + list of those that do not
    local n=$1; shift
    run "$n" "for f in $*; do [ -e \$f ] || echo \$f; done" > "$BK/nodes/$n.absent"
    # -T - : an empty list still gives a valid (empty) archive
    run "$n" "for f in $*; do [ -e \$f ] && echo \${f#/}; done | tar -C / -czf - -T -" > "$BK/nodes/$n.tgz"
    tar -tzf "$BK/nodes/$n.tgz" >/dev/null || die "backup of $n is unreadable"
    ok "node $n: $(tar -tzf "$BK/nodes/$n.tgz" | wc -l) files"
}

step_backup() {
    local n suf rep
    say "Backup -> $BK"
    mkdir -p "$BK/nodes" "$BK/keycloak" "$BK/ceph" "$BK/k8s"
    for n in "${NODES[@]}"; do backup_node "$n" "${NODE_FILES[@]}"; done
    for n in "${COMPUTES[@]}"; do backup_node "$n" "${COMPUTE_FILES[@]}"; done
    for suf in "${KC_CLIENTS[@]}"; do
        for rep in "https://$VIP:$suf" "https://$DOMAIN:$suf"; do
            kc_find "$rep" > "$BK/keycloak/$(tr -c 'A-Za-z0-9' _ <<<"$rep").json"
        done
    done
    os identity provider show "$IDP" -f json | jq -r '.remote_ids | if type=="array" then .[] else split(", ")[] end' \
        > "$BK/keystone-remote-ids"
    ceph_local_keys > "$BK/ceph/localized"
    for rep in mgr/dashboard/crt mgr/dashboard/key mgr/restful/crt mgr/restful/key mgr/dashboard/ssodb_v1 \
               $(cat "$BK/ceph/localized"); do
        ceph config-key get "$rep" > "$BK/ceph/${rep//\//_}" 2>/dev/null || true
    done
    ceph dashboard get-grafana-api-url > "$BK/ceph/grafana-api-url"
    kubectl get authconfigs.management.cattle.io keycloak -o json > "$BK/k8s/authconfig-keycloak.json"
    chmod -R go-rwx "$BK"
    ok "Keycloak clients, keystone remote IDs, ceph keys/SSO, Rancher authconfig saved (contains private keys: mode 600)."
}

# ------------------------------------------------------------------ apply steps
step_keycloak() {
    local suf src dst rep cur uuid setcert b64 keep
    say "Keycloak clients"
    mark keycloak
    b64=$(openssl x509 -in "$WORK/leaf.pem" -outform der | base64 -w0)
    # Hand-made setups renamed the platform's IP clients to the FQDN. Put the IP clients back
    # first (terraform manages them by UUID under the IP name); the loop below then adds the
    # FQDN clients as separate copies, as on any other cluster.
    for suf in "${KC_CLIENTS[@]}"; do
        (( ! FQDN_ONLY )) || break
        src=https://$VIP:$suf dst=https://$DOMAIN:$suf
        [[ -z $(kc_find "$src") ]] || continue
        cur=$(kc_find "$dst"); [[ -n $cur ]] || die "Keycloak client $src not found"
        uuid=$(jq -r .id <<<"$cur")
        jq --arg from "https://${DOMAIN//./\\.}:" --arg to "https://$VIP:" \
            'walk(if type == "string" then gsub($from; $to) else . end)' <<<"$cur" > "$WORK/client-ip.json"
        if [[ $uuid == "$(tf_client_uuid "$suf")" ]]; then
            kc PUT "/clients/$uuid" --data-binary @"$WORK/client-ip.json" >/dev/null
            echo "updated $uuid $(tr -c 'A-Za-z0-9' _ <<<"$dst").json" >> "$BK/keycloak/changes"
            ok "renamed $dst back to $src (terraform's client $uuid)"
        else
            jq 'del(.id) | if .protocolMappers then .protocolMappers |= map(del(.id)) else . end' \
                "$WORK/client-ip.json" > "$WORK/client-ip-new.json"
            kc POST /clients --data-binary @"$WORK/client-ip-new.json" >/dev/null
            echo "created $(kc_find "$src" | jq -r .id)" >> "$BK/keycloak/changes"
            ok "recreated $src as a copy of $dst"
        fi
    done
    for suf in "${KC_CLIENTS[@]}"; do
        src=https://$VIP:$suf dst=https://$DOMAIN:$suf
        cur=$(kc_find "$dst")
        if (( FQDN_ONLY )) && [[ -n $cur ]]; then  # keep the client; only api+ceph carry the SP cert
            uuid=$(jq -r .id <<<"$cur")
            if [[ $KC_CERT_CLIENTS == *" $suf "* ]]; then
                jq --arg cert "$b64" '.attributes["saml.signing.certificate"] = $cert
                    | .attributes["saml.encryption.certificate"] = $cert' <<<"$cur" > "$WORK/client-put.json"
                kc PUT "/clients/$uuid" --data-binary @"$WORK/client-put.json" >/dev/null
                echo "updated $uuid $(tr -c 'A-Za-z0-9' _ <<<"$dst").json" >> "$BK/keycloak/changes"
                ok "kept $dst, certificate updated"
            else
                ok "kept $dst as is"
            fi
            continue
        fi
        rep=$(kc_find "$src"); [[ -n $rep ]] || die "Keycloak client $src not found"
        setcert=false; [[ $KC_CERT_CLIENTS == *" $suf "* ]] && setcert=true
        jq --arg from "https://${VIP//./\\.}:" --arg to "https://$DOMAIN:" --arg cert "$b64" --argjson setcert "$setcert" '
            del(.id)
            | walk(if type == "string" then gsub($from; $to) else . end)
            | if .protocolMappers then .protocolMappers |= map(del(.id)) else . end
            | if $setcert then .attributes["saml.signing.certificate"] = $cert
                             | .attributes["saml.encryption.certificate"] = $cert else . end' \
            <<<"$rep" > "$WORK/client.json"
        cur=$(kc_find "$dst")
        if [[ -n $cur ]]; then
            uuid=$(jq -r .id <<<"$cur")
            jq --arg id "$uuid" '.id = $id' "$WORK/client.json" > "$WORK/client-put.json"
            kc PUT "/clients/$uuid" --data-binary @"$WORK/client-put.json" >/dev/null
            echo "updated $uuid $(tr -c 'A-Za-z0-9' _ <<<"$dst").json" >> "$BK/keycloak/changes"
            ok "updated $dst"
        else
            kc POST /clients --data-binary @"$WORK/client.json" >/dev/null
            uuid=$(kc_find "$dst" | jq -r .id)
            echo "created $uuid" >> "$BK/keycloak/changes"
            ok "created $dst"
        fi
        # same default client scopes as the source (the platform gives the ceph client none)
        keep=$(jq -c '.defaultClientScopes // []' <<<"$rep")
        kc GET "/clients/$uuid/default-client-scopes" \
            | jq -r --argjson keep "$keep" '.[] | select(.name as $n | $keep | index($n) | not) | .id' \
            | while read -r cur; do kc DELETE "/clients/$uuid/default-client-scopes/$cur" >/dev/null; done
    done
}

step_keystone() {
    local eid=https://$DOMAIN:10443/auth/realms/master r args=()
    say "Keystone identity provider"
    mark keystone
    if grep -qxF "$eid" "$BK/keystone-remote-ids"; then ok "$eid already a remote ID"; return 0; fi
    while read -r r; do [[ -n $r ]] && args+=(--remote-id "$r"); done < "$BK/keystone-remote-ids"
    os identity provider set "$IDP" "${args[@]}" --remote-id "$eid"
    ok "$IDP remote IDs: $(os identity provider show "$IDP" -f json | jq -c .remote_ids)"
}

step_k8s() {
    local ns ing
    say "k3s: Keycloak / Rancher on $DOMAIN:10443"
    mark k8s
    for ns in cattle-system keycloak; do
        kubectl -n "$ns" create secret tls "$SECRET" --cert="$WORK/server.cert" --key="$WORK/server.key" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    done
    for ing in cattle-system/rancher keycloak/keycloak; do
        kubectl -n "${ing%/*}" get ingress "${ing#*/}" -o json | jq --arg h "$DOMAIN" --arg s "$SECRET" '{
            apiVersion, kind,
            metadata: {name: (.metadata.name + "-fqdn"), namespace: .metadata.namespace,
                       labels: {"app.kubernetes.io/managed-by": "set-domain.sh"},
                       annotations: ((.metadata.annotations // {})
                                     | with_entries(select(.key | startswith("nginx.ingress.kubernetes.io/"))))},
            spec: (.spec | .rules |= map(.host = $h) | .tls = [{hosts: [$h], secretName: $s}])}' \
            | kubectl apply -f - >/dev/null
        ok "ingress ${ing}-fqdn"
    done
}

node_apply() {
    cat <<'EOS'
set -Eeuo pipefail
D=$1 S=$2
trap 'echo "node $(hostname -s): failed at line $LINENO" >&2' ERR
# in place, so /var/www/certs keeps exactly 3 files (health_httpd_repair re-syncs from a peer otherwise)
cat "$S/server.cert" > /var/www/certs/server.cert
cat "$S/server.key"  > /var/www/certs/server.key
cat "$S/server.pem"  > /var/www/certs/server.pem
# nova keeps its own copy and only creates it when missing
if [ -f /var/lib/nova/certs/server.pem ]; then cat "$S/server.pem" > /var/lib/nova/certs/server.pem
else install -D -o nova -g nova -m 600 "$S/server.pem" /var/lib/nova/certs/server.pem; fi
# IdP descriptor with the FQDN issuer (mellon, ceph SSO)
cat "$S/idp-metadata.xml" > /etc/keycloak/saml-metadata.xml
# mellon SP metadata on the FQDN; keeps this node's v3.key / v3.cert
sed -i -E "s#https://[^/\"]+:5443/v3/mellon#https://$D:5443/v3/mellon#g" /etc/httpd/federation/v3.xml
# 3.1.0 bug: "WSGIProcessGroup keystone-ssl;" makes every keystone request on 5443 a 500
# ("No WSGI daemon process called 'keystone-ssl;'"); only mellon's redirects worked there
sed -i -E 's/^([[:space:]]*WSGIProcessGroup keystone-ssl);[[:space:]]*$/\1/' \
    /etc/httpd/conf.d/keystone-wsgi.conf /etc/httpd/conf.d/keystone-wsgi.conf.in
# 5443 (httpd keystone vhost) and 9999 (nginx) must load the full chain written above. Hand edits
# on some clusters point them at other files (leaf only / old chain file): pin the platform paths
# and drop any separate chain file, in the templates too.
for f in /etc/httpd/conf.d/keystone-wsgi.conf /etc/httpd/conf.d/keystone-wsgi.conf.in; do
    sed -i -E '/^<VirtualHost \*:5443>/,/^<\/VirtualHost>/{
        s#^([[:space:]]*SSLCertificateFile[[:space:]]+).*#\1/var/www/certs/server.cert#
        s#^([[:space:]]*SSLCertificateKeyFile[[:space:]]+).*#\1/var/www/certs/server.key#
        /^[[:space:]]*SSLCertificateChainFile[[:space:]]/d
    }' "$f"
done
for f in /etc/nginx/nginx.conf /etc/nginx/nginx.conf.in; do
    [ -f "$f" ] || continue
    sed -i -E -e 's#^([[:space:]]*ssl_certificate[[:space:]]+)[^;]+;#\1/var/www/certs/server.cert;#' \
              -e 's#^([[:space:]]*ssl_certificate_key[[:space:]]+)[^;]+;#\1/var/www/certs/server.key;#' "$f"
done
t=$(httpd -t 2>&1) || { echo "httpd config test failed: $t" >&2; exit 1; }
nginx -t -q || { echo "nginx config test failed" >&2; exit 1; }
# cube-cos-api spec.listen.domainName; the template too, commit regenerates the yaml from it
for f in /etc/cube/api/cube-cos-api.yaml /etc/cube/api/cube-cos-api.yaml.in; do
    sed -i -E '/^  listen:$/{n;/^    domainName:/d}' "$f"
    sed -i -E "s#^  listen:\$#&\n    domainName: $D#" "$f"
    grep -q "^    domainName: $D\$" "$f"
done
# skyline: SSO + API on https :5443, the same origin as the mellon ACS
for f in /etc/skyline/skyline.yaml /etc/skyline/skyline.yaml.in; do
    sed -i -E "s#^(  keystone_url: ).*#\1https://$D:5443/v3/#" "$f"
    grep -q "^  keystone_url: https://$D:5443/v3/\$" "$f"
done
for f in /etc/openstack-dashboard/local_settings /etc/openstack-dashboard/local_settings.in; do
    [ -f "$f" ] || continue
    sed -i '/^WEBSSO_KEYSTONE_URL = /d' "$f"
    echo "WEBSSO_KEYSTONE_URL = \"https://$D:5443/v3\"" >> "$f"
done
# keystone: accept the FQDN dashboards, keep the platform's IP entries
# (keystone reads keystone.conf.d after keystone.conf; create it when the node has none)
[ -d /etc/keystone/keystone.conf.d ] || install -d -m 755 -o root -g root /etc/keystone/keystone.conf.d
{ echo '# written by set-domain.sh'; echo '[federation]'
  grep -E '^trusted_dashboard[[:space:]]*=' /etc/keystone/keystone.conf || true
  echo "trusted_dashboard = https://$D/horizon/auth/websso/"
  echo "trusted_dashboard = https://$D:9999/api/openstack/skyline/api/v1/websso"
} > /etc/keystone/keystone.conf.d/90-fqdn.conf
chown root:keystone /etc/keystone/keystone.conf.d/90-fqdn.conf; chmod 640 /etc/keystone/keystone.conf.d/90-fqdn.conf
# nova-compute builds the console URL; it reads /etc/nova/nova.d after nova.conf
printf '[vnc]\nnovncproxy_base_url = https://%s:6080/vnc_auto.html\n' "$D" > /etc/nova/nova.d/90-fqdn.conf
chown root:nova /etc/nova/nova.d/90-fqdn.conf; chmod 640 /etc/nova/nova.d/90-fqdn.conf
mkdir -p /etc/systemd/system/grafana-server.service.d
printf '[Service]\nEnvironment=GF_SERVER_ROOT_URL=https://%s/grafana\n' "$D" \
    > /etc/systemd/system/grafana-server.service.d/90-fqdn.conf
systemctl daemon-reload
rm -rf "$S"
EOS
}

node_restart() {
    cat <<'EOS'
set -uo pipefail
r="skyline-apiserver openstack-nova-novncproxy grafana-server cube-cos-api"
# pure control nodes run no nova-compute; restart it only where it runs
systemctl is-active -q openstack-nova-compute && r="$r openstack-nova-compute"
# 3.2+: keystone is gunicorn (openstack-keystone) behind an httpd proxy and reads keystone.conf.d
# only at start; an httpd reload no longer restarts it (3.1 ran it inside httpd via mod_wsgi)
systemctl is-active -q openstack-keystone && r="$r openstack-keystone"
systemctl reload haproxy nginx httpd
systemctl restart $r
sleep 30
rc=0
for u in haproxy nginx httpd $r; do systemctl is-active -q "$u" || { echo "FAILED: $u is not active on $(hostname -s)"; rc=1; }; done
if [ "$(systemctl show -p NRestarts --value cube-cos-api)" != 0 ]; then
    echo "FAILED: cube-cos-api is restarting on $(hostname -s):"
    grep -iE 'error|fail' /var/log/cube-cos-api/cube-cos-api.log | tail -5
    rc=1
fi
exit $rc
EOS
}

step_nodes() {
    local n p fp want order=()
    want=$(openssl x509 -in "$WORK/leaf.pem" -noout -fingerprint -sha256 | cut -d= -f2)
    for n in "${NODES[@]}"; do [[ $n == "$SELF" ]] || order+=("$n"); done
    order+=("$SELF")
    for n in "${order[@]}"; do
        say "Node $n"
        mark "node:$n"
        run "$n" "rm -rf $STAGE && install -d -m 700 $STAGE"
        for p in server.cert server.key server.pem idp-metadata.xml; do
            pipe_to "$n" "cat > $STAGE/$p" < "$WORK/$p"
        done
        node_apply | on "$n" "$DOMAIN" "$STAGE"
        ok "files written"
        node_restart | on "$n" || die "services on $n did not come back (see above)"
        for p in 443 5443 9999 6080; do
            fp=$(tls_fp "$n" "$p")
            [[ $fp == "$want" ]] || die "node $n port $p serves ${fp:-nothing}, not the new certificate"
        done
        ok "services active; 443 5443 9999 6080 serve the new certificate"
        p=$(run "$n" "curl -sk -o /dev/null -w '%{http_code}' https://$n:5443/v3") || p=""
        [[ $p == 200 ]] || die "node $n: keystone on 5443 answers ${p:-nothing}, not 200 (see /var/log/httpd/keystone-ssl.log)"
        ok "keystone API on 5443 answers 200"
    done
}

step_computes() {
    local n
    for n in "${COMPUTES[@]}"; do
        say "Compute $n"
        mark "compute:$n"
        run "$n" "printf '[vnc]\nnovncproxy_base_url = https://%s:6080/vnc_auto.html\n' '$DOMAIN' > /etc/nova/nova.d/90-fqdn.conf \
            && chown root:nova /etc/nova/nova.d/90-fqdn.conf && chmod 640 /etc/nova/nova.d/90-fqdn.conf \
            && systemctl restart openstack-nova-compute && sleep 15 && systemctl is-active -q openstack-nova-compute" \
            || die "nova-compute on $n did not come back (journalctl -u openstack-nova-compute)"
        ok "nova-compute restarted; console URL https://$DOMAIN:6080/vnc_auto.html"
    done
}

ceph_reload() {
    local m
    for m in dashboard restful; do ceph mgr module disable "$m"; ceph mgr module enable "$m"; done
    # haproxy-ha only routes to the active mgr once its health check (GET /ceph/ == 200) passes
    # again; until then requests land on a standby, which answers 303 and fails the SSO test.
    local good=0
    for _ in $(seq 1 60); do
        if [[ $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$VIP:7443/ceph/") == 200 ]]; then
            good=$((good + 1)); (( good >= 3 )) && { ok "dashboard back on VIP:7443"; return 0; }
        else
            good=0
        fi
        sleep 3
    done
    warn "VIP:7443 did not return 200 from the active mgr within 3 minutes"
}

ceph_local_keys() {  # per-mgr cert overrides: mgr/dashboard/<mgr>/crt|key, mgr/restful/<mgr>/crt|key
    ceph config-key ls | jq -r '.[] | select(test("^mgr/(dashboard|restful)/[^/]+/(crt|key)$"))'
}

step_ceph() {
    local mgr
    say "Ceph"
    mark ceph
    ceph dashboard set-ssl-certificate -i "$WORK/server.cert"
    ceph dashboard set-ssl-certificate-key -i "$WORK/server.key"
    ceph config-key set mgr/restful/crt -i "$WORK/server.cert" >/dev/null
    ceph config-key set mgr/restful/key -i "$WORK/server.key" >/dev/null
    # per-mgr keys (mgr/<module>/<mgr>/crt|key) win over the global ones; overwrite them too
    while read -r rep; do
        [[ -n $rep ]] || continue
        if [[ $rep == */crt ]]; then ceph config-key set "$rep" -i "$WORK/server.cert" >/dev/null
        else ceph config-key set "$rep" -i "$WORK/server.key" >/dev/null; fi
        ok "per-mgr override $rep updated"
    done < "$BK/ceph/localized"
    ceph dashboard set-grafana-api-url "https://$DOMAIN/grafana"
    ceph_reload
    mgr=$(ceph mgr stat -f json | jq -r .active_name)
    echo "SSO via $(basename "$CEPH_SSO") on the active mgr host $mgr"
    on "$(node_ip "$mgr")" --fqdn "$DOMAIN" --apply < "$CEPH_SSO" || die "Ceph SSO apply failed (see above)"
}

step_rancher() {
    say "Rancher keycloak authconfig"
    mark rancher
    jq -n --arg h "https://$DOMAIN:10443" --rawfile md "$WORK/idp-metadata.xml" \
        '{rancherApiHost: $h, idpMetadataContent: $md}' > "$WORK/authconfig.json"
    kubectl patch authconfigs.management.cattle.io keycloak --type merge --patch-file "$WORK/authconfig.json" >/dev/null
    kubectl -n cattle-system rollout restart deploy/rancher >/dev/null
    kubectl -n cattle-system rollout status deploy/rancher --timeout=600s
}

md_check() {  # md_check PORT PATH EXPECTED_ENTITY_ID
    local got
    got=$(curl -s --max-time 20 --resolve "$DOMAIN:$1:$VIP" "https://$DOMAIN:$1$2" \
        | grep -o 'entityID="[^"]*"' | head -1 | cut -d'"' -f2) || got=""
    if [[ $got == "$3" ]]; then ok "$DOMAIN:$1$2 entityID $got"; else warn "$DOMAIN:$1$2 entityID '${got:-none}', expected $3"; fi
}

# domain_check: what a user gets through DNS on every port -- the served chain must be exactly
# server.cert (leaf + intermediates), trusted by the system CA bundle for DOMAIN, and HTTP must answer.
domain_check() {
    local p ip c want served res code vr trust
    say "Domain check: https://$DOMAIN"
    ip=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}') || ip=""
    if [[ $ip == "$VIP" ]]; then ok "$DOMAIN resolves to the VIP $VIP"
    else warn "$DOMAIN resolves to '${ip:-nothing}', not the VIP $VIP"; fi
    echo "Expected chain (server.cert):"
    split_pem "$WORK/server.cert" "$WORK/expect"
    for c in "$WORK"/expect/*.pem; do
        echo "  - $(subj "$c")"
        echo "    issuer $(issuer "$c")  expires $(openssl x509 -in "$c" -noout -enddate | cut -d= -f2)"
        echo "    SHA-256 $(openssl x509 -in "$c" -noout -fingerprint -sha256 | cut -d= -f2)"
    done
    want=$(chain_fps "$WORK/server.cert")
    for p in 443 5443 9999 6080 7443 8005 10443; do
        echo | timeout 10 openssl s_client -connect "$DOMAIN:$p" -servername "$DOMAIN" -showcerts \
            > "$WORK/served.pem" 2>/dev/null || true
        served=$(chain_fps "$WORK/served.pem")
        res=$(curl -s -o /dev/null --max-time 20 --cacert "$CA_BUNDLE" -w '%{http_code} %{ssl_verify_result}' \
            "https://$DOMAIN:$p/") || true
        code=${res% *} vr=${res#* }
        if [[ $vr == 0 && $code != 000 ]]; then trust="trusted, hostname ok, HTTP $code"
        else trust="NOT trusted by $CA_BUNDLE (curl verify result ${vr:-?}): browsers/SSO calls fail"; fi
        if [[ -z $served ]]; then warn "$DOMAIN:$p no TLS answer"
        elif [[ ${served%%$'\n'*} != "${want%%$'\n'*}" ]]; then warn "$DOMAIN:$p serves ${served%%$'\n'*}, not the new certificate"
        elif [[ $served != "$want" ]]; then
            warn "$DOMAIN:$p new leaf, but sends $(grep -c . <<<"$served") cert(s), not server.cert's $(grep -c . <<<"$want"): [$(served_cns)]; $trust"
        elif [[ $trust != trusted* ]]; then warn "$DOMAIN:$p chain = server.cert, but $trust"
        else ok "$DOMAIN:$p chain = server.cert ($(grep -c . <<<"$served") certs), $trust"; fi
    done
}
served_cns() {  # CNs of the chain in $WORK/served.pem, in order
    local c
    rm -rf "$WORK/served"; split_pem "$WORK/served.pem" "$WORK/served"
    for c in "$WORK"/served/*.pem; do
        if [[ -e $c ]]; then subj "$c" | sed -E 's/^.*CN=([^,]+).*$/\1/'; fi
    done | paste -sd'>' - | sed 's/>/ > /g'
}

step_verify() {
    local s
    domain_check
    say "SAML / SSO / Rancher / Ceph"
    # cube-cos-api serves no SP metadata (/saml/metadata answers 302 -> /home, on the IP too), but it
    # exits at startup when the Keycloak client https://DOMAIN:443/saml/metadata is missing.
    # NRestarts counts every auto-restart since the unit was last started by hand, so judge by
    # how long the current process has been up instead.
    local up
    for s in "${NODES[@]}"; do
        up=$(run "$s" 'p=$(systemctl show cube-cos-api -p MainPID --value); [ "$(systemctl is-active cube-cos-api)" = active ] && [ "${p:-0}" != 0 ] && ps -o etimes= -p "$p" | tr -d " "') || up=""
        if [[ $up =~ ^[0-9]+$ ]] && (( up >= 60 )); then
            ok "node $s cube-cos-api up ${up}s (Keycloak client https://$DOMAIN:443/saml/metadata accepted)"
        else
            warn "node $s cube-cos-api not active or restarted <60s ago (${up:-down}; check: journalctl -u cube-cos-api)"
        fi
    done
    md_check 5443 /v3/mellon/metadata "https://$DOMAIN:5443/v3/mellon/metadata"
    md_check 7443 /ceph/auth/saml2/metadata "https://$DOMAIN:7443/ceph/auth/saml2/metadata"
    md_check 10443 /v1-saml/keycloak/saml/metadata "https://$DOMAIN:10443/v1-saml/keycloak/saml/metadata"
    md_check 10443 /auth/realms/master/protocol/saml/descriptor "https://$DOMAIN:10443/auth/realms/master"
    s=$(curl -s --max-time 20 --resolve "$DOMAIN:9999:$VIP" "https://$DOMAIN:9999/api/openstack/skyline/api/v1/sso") || s=""
    if [[ $s == *"https://$DOMAIN:5443/v3/auth/OS-FEDERATION/websso"* ]]; then ok "Skyline SSO starts at https://$DOMAIN:5443"
    else warn "Skyline SSO URL does not point at https://$DOMAIN:5443: ${s:0:200}"; fi
    s=$(kubectl get clusters.management.cattle.io -o jsonpath='{range .items[*]}{.spec.displayName}={.status.conditions[?(@.type=="Ready")].status} {end}') || s=""
    [[ $s != *=False* && -n $s ]] && ok "Rancher clusters: $s" || warn "Rancher clusters: $s"
    echo "Ceph: $(ceph health 2>&1 | head -1); $(ceph dashboard sso status 2>&1)"
}

# ------------------------------------------------------------------ rollback
do_rollback() {
    local n line act uuid f r args=()
    # shellcheck disable=SC1091
    source "$BK/meta"
    say "Rollback $DOMAIN from $BK"
    echo "Steps that ran: $(tr '\n' ' ' < "$BK/steps")"
    confirm "This restores the backup on ${NODES[*]}, Ceph, Keycloak, Keystone and Rancher."
    kc_init
    if begun rancher; then
        say "Rancher"
        jq '{rancherApiHost, idpMetadataContent}' "$BK/k8s/authconfig-keycloak.json" > "$WORK/authconfig.json"
        kubectl patch authconfigs.management.cattle.io keycloak --type merge --patch-file "$WORK/authconfig.json" >/dev/null
        kubectl -n cattle-system rollout restart deploy/rancher >/dev/null
        kubectl -n cattle-system rollout status deploy/rancher --timeout=600s
    fi
    if begun k8s; then
        say "k3s"
        kubectl -n cattle-system delete ingress rancher-fqdn --ignore-not-found
        kubectl -n keycloak delete ingress keycloak-fqdn --ignore-not-found
        kubectl -n cattle-system delete secret "$SECRET" --ignore-not-found
        kubectl -n keycloak delete secret "$SECRET" --ignore-not-found
    fi
    if begun ceph; then
        say "Ceph"
        for f in mgr/dashboard/crt mgr/dashboard/key mgr/restful/crt mgr/restful/key mgr/dashboard/ssodb_v1 \
                 $(cat "$BK/ceph/localized" 2>/dev/null); do
            if [[ -s $BK/ceph/${f//\//_} ]]; then ceph config-key set "$f" -i "$BK/ceph/${f//\//_}" >/dev/null; fi
        done
        ceph dashboard set-grafana-api-url "$(cat "$BK/ceph/grafana-api-url")"
        ceph_reload
        ceph dashboard sso status
    fi
    for n in "${NODES[@]}"; do
        begun "node:$n" || continue
        say "Node $n"
        pipe_to "$n" "tar -C / -xzpf -" < "$BK/nodes/$n.tgz"
        # paths that did not exist before the run, incl. a keystone.conf.d this script created
        pipe_to "$n" "xargs -r rm -rf" < "$BK/nodes/$n.absent"
        run "$n" "systemctl daemon-reload; rm -rf $STAGE"
        node_restart | on "$n" || warn "services on $n need a look (see above)"
    done
    for n in $(sed -n 's/^compute://p' "$BK/steps"); do
        say "Compute $n"
        pipe_to "$n" "tar -C / -xzpf -" < "$BK/nodes/$n.tgz"
        pipe_to "$n" "xargs -r rm -rf" < "$BK/nodes/$n.absent"
        run "$n" "systemctl restart openstack-nova-compute" || warn "nova-compute on $n needs a look"
    done
    if begun keystone; then
        say "Keystone"
        while read -r r; do [[ -n $r ]] && args+=(--remote-id "$r"); done < "$BK/keystone-remote-ids"
        os identity provider set "$IDP" "${args[@]}"
        ok "$IDP remote IDs: $(os identity provider show "$IDP" -f json | jq -c .remote_ids)"
    fi
    if begun keycloak && [[ -f $BK/keycloak/changes ]]; then
        say "Keycloak"
        while read -r act uuid f; do
            if [[ $act == created ]]; then kc DELETE "/clients/$uuid" >/dev/null && ok "deleted client $uuid"
            else kc PUT "/clients/$uuid" --data-binary @"$BK/keycloak/$f" >/dev/null && ok "restored client $uuid"; fi
        done < <(tac "$BK/keycloak/changes")  # newest first: drop copies before renaming back
    fi
    rm -rf "$WORK"
    say "Rollback done"
    echo "Check: https://$VIP (old certificate), Skyline / Ceph / Rancher login via the IP."
}

# ------------------------------------------------------------------ main
main() {
    local arg t
    DOMAIN="" CERT_DIR="" BK=""
    while (( $# )); do
        arg=$1
        case $arg in
            -c|--certs) CERT_DIR=${2:?-c needs a directory}; shift ;;
            --check) MODE=check ;;
            --apply) MODE=apply ;;
            --verify) MODE=verify ;;
            --rollback) MODE=rollback; BK=${2:?--rollback needs the backup directory}; shift ;;
            -y|--yes) YES=1 ;;
            --fqdn-only) FQDN_ONLY=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage; die "unknown option: $arg" ;;
            *) [[ -z $DOMAIN ]] || die "extra argument: $arg"; DOMAIN=$(tr 'A-Z' 'a-z' <<<"$arg") ;;
        esac
        shift
    done
    (( EUID == 0 )) || die "run as root on a control node"
    for t in openssl curl jq kubectl ceph openstack ssh tar base64 timeout; do
        command -v "$t" >/dev/null || die "missing command: $t"
    done
    VIP=$(tune cubesys.control.vip)
    IFS=, read -r -a NODES <<<"$(tune cubesys.control.addrs)"
    IFS=, read -r -a HOSTS <<<"$(tune cubesys.control.hosts)"
    [[ -n $VIP && ${#NODES[@]} -gt 0 && ${#NODES[@]} -eq ${#HOSTS[@]} ]] || die "cannot read VIP / control nodes from /etc/settings.txt (HA clusters only)"
    SELF=""
    for t in "${NODES[@]}"; do
        if ip -o -4 addr show | grep -q " $t/"; then SELF=$t; fi
    done
    [[ -n $SELF ]] || die "this host is not one of the control nodes ${NODES[*]}"

    if [[ $MODE == rollback ]]; then
        [[ -f $BK/meta && -f $BK/steps ]] || die "not a set-domain backup directory: $BK"
        WORK=$BK/work; mkdir -p -m 700 "$WORK"
        exec > >(tee -a "$BK/rollback-$(date +%Y%m%d-%H%M%S).log") 2>&1
        trap 'echo "STOP: rollback failed at line $LINENO (step: ${STEP:-?}); fix the cause and re-run the same command."' ERR
        do_rollback
        exit 0
    fi

    [[ -n $DOMAIN && -n $CERT_DIR ]] || { usage; die "DOMAIN and -c CERT_DIR are required"; }
    [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "invalid domain: $DOMAIN"
    CERT_DIR=$(cd "$CERT_DIR" && pwd)
    SECRET=tls-${DOMAIN//./-}
    BK=/root/set-domain-backup/$DOMAIN-$(date +%Y%m%d-%H%M%S)
    WORK=$BK/work
    mkdir -p -m 700 "$BK" "$WORK"
    exec > >(tee -a "$BK/set-domain.log") 2>&1
    trap 'echo "STOP: failed at line $LINENO (step: ${STEP:-?})." >&2' ERR
    # die() exits without ERR, so the rollback hint lives on EXIT
    trap 'rc=$?; if (( rc != 0 )) && [[ -s $BK/steps ]]; then echo "Roll back with: $0 --rollback $BK" >&2; fi' EXIT
    printf 'DOMAIN=%q\nVIP=%q\nSECRET=%q\n' "$DOMAIN" "$VIP" "$SECRET" > "$BK/meta"

    if [[ $MODE == verify ]]; then
        build_certs "$DOMAIN" "$CERT_DIR" "$WORK"
        step_verify
        rm -rf "$WORK"
        say "Result"
        echo "Warnings: $WARNS. Nothing changed. Log: $BK/set-domain.log"
        (( WARNS == 0 )) || exit 2
        exit 0
    fi
    preflight
    plan
    if [[ $MODE == check ]]; then
        say "Result"
        rm -rf "$WORK"
        (( PROBLEMS == 0 )) || { echo "$PROBLEMS problem(s). Log: $BK/set-domain.log"; exit 2; }
        echo "Ready ($WARNS warning(s)). Nothing changed. To apply: $0 $DOMAIN -c $CERT_DIR --apply$( (( FQDN_ONLY )) && echo " --fqdn-only" )"
        echo "Log: $BK/set-domain.log"
        exit 0
    fi
    (( PROBLEMS == 0 )) || die "$PROBLEMS problem(s) above; nothing changed."
    confirm "Users lose SSO sessions; each node's services restart in turn; Rancher restarts."
    : > "$BK/steps"
    step_backup
    step_keycloak
    step_keystone
    step_k8s
    step_nodes
    step_computes
    step_ceph
    step_rancher
    step_verify
    rm -rf "$WORK"
    say "Done"
    echo "Warnings: $WARNS. Backup + log: $BK   Rollback: $0 --rollback $BK"
    cat <<EOF
Test in a browser (private window):
  https://$DOMAIN/                       CubeCOS UI login via Keycloak
  https://$DOMAIN:9999/                  Skyline SSO
  https://$DOMAIN:7443/ceph/             Ceph dashboard SSO (the Ceph user must exist)
  https://$DOMAIN:10443/                 Rancher, Keycloak login
  https://$DOMAIN/horizon/               Horizon WebSSO (if used)
  a VM console in Skyline                noVNC on https://$DOMAIN:6080
EOF
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
