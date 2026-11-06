#!/usr/bin/env bash
set -Eeuo pipefail

SSH_TARGET="bigstack@10.32.0.201"
ZONE_NAME="bigstack.co"
CREDENTIALS_FILE="/home/bigstack/.secrets/cloudflare.ini"

usage() {
  printf 'Usage: %s SUBDOMAIN IPV4_ADDRESS\n' "${0##*/}" >&2
  exit 2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage

SUBDOMAIN=$1
IP=$2

if [[ ! $SUBDOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
  fail "SUBDOMAIN must contain valid DNS labels without the .bigstack.co suffix"
fi

if [[ ! $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  fail "IPV4_ADDRESS must be an IPv4 address"
fi

IFS=. read -r octet1 octet2 octet3 octet4 <<< "$IP"
for octet in "$octet1" "$octet2" "$octet3" "$octet4"; do
  if ((10#$octet > 255)); then
    fail "IPV4_ADDRESS must be an IPv4 address"
  fi
done
IP=$(printf '%d.%d.%d.%d' "$((10#$octet1))" "$((10#$octet2))" "$((10#$octet3))" "$((10#$octet4))")

for command in ssh mktemp chmod mv; do
  command -v "$command" >/dev/null 2>&1 || fail "Required local command not found: $command"
done

FQDN="${SUBDOMAIN}.${ZONE_NAME}"
(( ${#FQDN} <= 253 )) || fail "The resulting fully qualified domain name is too long"
OUTPUT_DIR=$PWD
umask 077
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/certbot-generator.XXXXXX")
trap 'rm -f "$TEMP_DIR/fullchain.pem" "$TEMP_DIR/privkey.pem"; rmdir "$TEMP_DIR"' EXIT

ssh "$SSH_TARGET" bash -s -- "$FQDN" "$IP" "$ZONE_NAME" "$CREDENTIALS_FILE" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

FQDN=$1
IP=$2
ZONE_NAME=$3
CREDENTIALS_FILE=$4
API_BASE="https://api.cloudflare.com/client/v4"
API_CONFIG=
API_BODY=
HTTP_STATUS=
RECORD_ID=
CLEANUP_SCRIPT=
CRON_MARKER=
CRONTAB_TMP=

for command in curl jq awk date crontab mktemp chmod grep openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Error: required remote command not found: %s\n' "$command" >&2
    exit 1
  }
done

[[ -r $CREDENTIALS_FILE ]] || {
  printf 'Error: cannot read Cloudflare credentials file: %s\n' "$CREDENTIALS_FILE" >&2
  exit 1
}

# Reissue only when an existing lineage has a non-RSA public key.
# Otherwise let Certbot reuse a still-valid RSA certificate.
CERTBOT_EXTRA_ARGS=()
if sudo -n test -f "/etc/letsencrypt/live/$FQDN/cert.pem"; then
  CERT_INFO=$(sudo -n openssl x509 \
    -in "/etc/letsencrypt/live/$FQDN/cert.pem" -noout -text)
  if ! grep -q 'Public Key Algorithm: rsaEncryption' <<< "$CERT_INFO"; then
    CERTBOT_EXTRA_ARGS+=(--force-renewal)
  fi
fi

printf 'Requesting RSA 2048 certificate for %s...\n' "$FQDN"
sudo -n certbot certonly \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --cert-name "$FQDN" \
  --key-type rsa \
  --rsa-key-size 2048 \
  "${CERTBOT_EXTRA_ARGS[@]}" \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CREDENTIALS_FILE" \
  -d "$FQDN"

TOKEN=$(awk -F= '
  /^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=/ {
    sub(/^[^=]*=/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    print
    exit
  }
' "$CREDENTIALS_FILE")

[[ $TOKEN =~ ^[A-Za-z0-9_-]+$ ]] || {
  printf 'Error: could not read a valid dns_cloudflare_api_token from %s\n' "$CREDENTIALS_FILE" >&2
  exit 1
}

umask 077
API_CONFIG=$(mktemp)
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$API_CONFIG"
unset TOKEN

cleanup_api_config() {
  [[ -z $API_CONFIG ]] || rm -f -- "$API_CONFIG"
}
trap cleanup_api_config EXIT

api_call() {
  local output
  output=$(curl --silent --show-error --connect-timeout 15 --max-time 60 \
    --config "$API_CONFIG" \
    -H 'Content-Type: application/json' \
    -w $'\n%{http_code}' "$@") || return 1
  HTTP_STATUS=${output##*$'\n'}
  API_BODY=${output%$'\n'*}

  if [[ ! $HTTP_STATUS =~ ^2[0-9][0-9]$ ]] || ! jq -e '.success == true' >/dev/null <<< "$API_BODY"; then
    printf 'Cloudflare API request failed (HTTP %s).\n' "$HTTP_STATUS" >&2
    jq -r '.errors[]? | "\(.code): \(.message)"' <<< "$API_BODY" >&2 || true
    return 1
  fi
}

api_call --get --data-urlencode "name=$ZONE_NAME" "$API_BASE/zones"
ZONE_COUNT=$(jq -r '.result | length' <<< "$API_BODY")
[[ $ZONE_COUNT == 1 ]] || {
  printf 'Error: expected exactly one Cloudflare zone named %s; found %s\n' "$ZONE_NAME" "$ZONE_COUNT" >&2
  exit 1
}
ZONE_ID=$(jq -er '.result[0].id' <<< "$API_BODY")

api_call --get \
  --data-urlencode 'type=A' \
  --data-urlencode "name=$FQDN" \
  "$API_BASE/zones/$ZONE_ID/dns_records"
EXISTING_COUNT=$(jq -r '.result | length' <<< "$API_BODY")
if [[ $EXISTING_COUNT == 1 ]] && \
  jq -e --arg ip "$IP" '.result[0].content == $ip and .result[0].proxied == false' >/dev/null <<< "$API_BODY"; then
  printf 'Keeping existing DNS A record for %s (%s); no new deletion schedule added.\n' "$FQDN" "$IP"
  printf 'Any previously scheduled DNS expiration remains unchanged.\n'
  exit 0
fi
[[ $EXISTING_COUNT == 0 ]] || {
  printf 'Error: existing A records for %s differ from the requested unproxied IP or are ambiguous; DNS left unchanged\n' "$FQDN" >&2
  exit 1
}

RECORD_PAYLOAD=$(jq -cn \
  --arg name "$FQDN" \
  --arg ip "$IP" \
  '{type:"A", name:$name, content:$ip, ttl:1, proxied:false, comment:"Temporary record; scheduled for deletion after 90 days"}')
api_call --request POST "$API_BASE/zones/$ZONE_ID/dns_records" --data "$RECORD_PAYLOAD"
RECORD_ID=$(jq -er '.result.id' <<< "$API_BODY")
[[ $RECORD_ID =~ ^[A-Fa-f0-9-]+$ ]] || {
  printf 'Error: Cloudflare returned an invalid DNS record ID\n' >&2
  exit 1
}
printf 'Created DNS A record for %s.\n' "$FQDN"

rollback_record() {
  local status=$?
  if [[ -n $RECORD_ID ]]; then
    if api_call --request DELETE "$API_BASE/zones/$ZONE_ID/dns_records/$RECORD_ID"; then
      printf 'Removed the new DNS record because setup did not complete.\n' >&2
    else
      printf 'Warning: could not roll back DNS record %s; check Cloudflare manually.\n' "$RECORD_ID" >&2
    fi
  fi
  [[ -z $CLEANUP_SCRIPT ]] || rm -f -- "$CLEANUP_SCRIPT"
  [[ -z $CRONTAB_TMP ]] || rm -f -- "$CRONTAB_TMP"
  cleanup_api_config
  exit "$status"
}
trap rollback_record EXIT

EXPIRATION_EPOCH=$(date -d '+90 days' +%s)
CRON_DIR="$HOME/.local/bin"
mkdir -p "$CRON_DIR"
CLEANUP_SCRIPT="$CRON_DIR/cloudflare-expire-$RECORD_ID.sh"
CRON_MARKER="cloudflare-expiry-$RECORD_ID"

cat > "$CLEANUP_SCRIPT" <<CLEANUP_SCRIPT_CONTENT
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
FQDN='$FQDN'
ZONE_ID='$ZONE_ID'
RECORD_ID='$RECORD_ID'
EXPIRATION_EPOCH='$EXPIRATION_EPOCH'
CREDENTIALS_FILE='$CREDENTIALS_FILE'
API_BASE='$API_BASE'
CRON_MARKER='$CRON_MARKER'

if (( \$(date +%s) < EXPIRATION_EPOCH )); then
  exit 0
fi

TOKEN=\$(awk -F= '
  /^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=/ {
    sub(/^[^=]*=/, "")
    gsub(/^[[:space:]]+|[[:space:]]+\$/, "")
    print
    exit
  }
' "\$CREDENTIALS_FILE")

if [[ ! \$TOKEN =~ ^[A-Za-z0-9_-]+\$ ]]; then
  printf 'Error: invalid Cloudflare API token in %s\n' "\$CREDENTIALS_FILE" >&2
  exit 1
fi

umask 077
API_CONFIG=\$(mktemp)
trap 'rm -f -- "\$API_CONFIG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "\$TOKEN" > "\$API_CONFIG"
unset TOKEN

api_call() {
  local output
  output=\$(curl --silent --show-error --connect-timeout 15 --max-time 60 \
    --config "\$API_CONFIG" \
    -H 'Content-Type: application/json' \
    -w \$'\n%{http_code}' "\$@") || return 1
  HTTP_STATUS=\${output##*\$'\n'}
  API_BODY=\${output%\$'\n'*}
}

remove_schedule() {
  local current_crontab filtered_crontab
  current_crontab=\$(mktemp)
  filtered_crontab=\$(mktemp)
  crontab -l > "\$current_crontab"
  grep -Fv "\$CRON_MARKER" "\$current_crontab" > "\$filtered_crontab" || true
  crontab "\$filtered_crontab"
  rm -f -- "\$current_crontab"
  rm -f -- "\$filtered_crontab"
  rm -f -- "\$0"
}

HTTP_STATUS=
API_BODY=
if ! api_call "\$API_BASE/zones/\$ZONE_ID/dns_records/\$RECORD_ID"; then
  printf 'Error: Cloudflare API request failed while checking %s\n' "\$FQDN" >&2
  exit 1
fi

if [[ \$HTTP_STATUS == 404 ]]; then
  printf 'DNS record %s was already absent; removing its expiration cron entry.\n' "\$FQDN"
  remove_schedule
  exit 0
fi

if [[ ! \$HTTP_STATUS =~ ^2[0-9][0-9]\$ ]] || ! jq -e '.success == true' >/dev/null <<< "\$API_BODY"; then
  printf 'Error: Cloudflare API returned HTTP %s while checking %s\n' "\$HTTP_STATUS" "\$FQDN" >&2
  jq -r '.errors[]? | "\(.code): \(.message)"' <<< "\$API_BODY" >&2 || true
  exit 1
fi

if ! api_call --request DELETE "\$API_BASE/zones/\$ZONE_ID/dns_records/\$RECORD_ID"; then
  printf 'Error: Cloudflare API request failed while deleting %s\n' "\$FQDN" >&2
  exit 1
fi
if [[ ! \$HTTP_STATUS =~ ^2[0-9][0-9]\$ ]] || ! jq -e '.success == true' >/dev/null <<< "\$API_BODY"; then
  printf 'Error: Cloudflare API returned HTTP %s while deleting %s\n' "\$HTTP_STATUS" "\$FQDN" >&2
  jq -r '.errors[]? | "\(.code): \(.message)"' <<< "\$API_BODY" >&2 || true
  exit 1
fi

printf 'Deleted DNS record for %s; removing its expiration cron entry.\n' "\$FQDN"
remove_schedule
CLEANUP_SCRIPT_CONTENT

chmod 700 "$CLEANUP_SCRIPT"
CRON_LINE="0 * * * * $CLEANUP_SCRIPT # $CRON_MARKER"
CRONTAB_TMP=$(mktemp)
(crontab -l 2>/dev/null || true) > "$CRONTAB_TMP"
printf '%s\n' "$CRON_LINE" >> "$CRONTAB_TMP"
crontab "$CRONTAB_TMP"
rm -f -- "$CRONTAB_TMP"
CRONTAB_TMP=

cleanup_api_config
trap - EXIT
printf 'Scheduled DNS deletion after 90 days; the hourly cron entry removes itself when deletion succeeds.\n'
REMOTE_SCRIPT

printf 'Saving certificate files to %s...\n' "$OUTPUT_DIR"
ssh "$SSH_TARGET" "sudo -n cat '/etc/letsencrypt/live/$FQDN/fullchain.pem'" > "$TEMP_DIR/fullchain.pem" ||
  fail "Could not read the full chain from the remote host"
ssh "$SSH_TARGET" "sudo -n cat '/etc/letsencrypt/live/$FQDN/privkey.pem'" > "$TEMP_DIR/privkey.pem" ||
  fail "Could not read the private key from the remote host"

chmod 600 "$TEMP_DIR/fullchain.pem" "$TEMP_DIR/privkey.pem"
mv "$TEMP_DIR/fullchain.pem" "$OUTPUT_DIR/$FQDN.pem"
mv "$TEMP_DIR/privkey.pem" "$OUTPUT_DIR/$FQDN.key"

printf 'Saved %s.pem and %s.key in %s\n' "$FQDN" "$FQDN" "$OUTPUT_DIR"
