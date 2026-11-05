#!/usr/bin/env bash
# Certificate inspection/conversion with Bash 3.2+ and OpenSSL.
set -Eeuo pipefail
trap 'exit 1' ERR
umask 077
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
 cat <<'HELP'
Usage: ssl-tool.sh
  -i FILE [-t]                            (inspect)
  -v -d DIR                               (verify)
  -x FILE -d DIR                          (pfx-extract; writes unencrypted private.key)
  -c -d DIR -o NEW_FILE                   (pfx-create)
  convert FILE -f PEM|DER -o NEW_FILE
  --url URL                               (show server certificate from curl)
Passwords are prompted unless environment variable names are supplied.
HELP
}
command -v openssl >/dev/null || fail 'openssl required'
PASS_ENV= OUT_PASS_ENV= LEGACY=0
URL=
COMMAND=
while [[ $# -gt 0 ]]; do
 case $1 in
 --pass-env|--out-pass-env)
  [[ $# -ge 2 ]] || fail 'Missing variable name'
  [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail 'Invalid variable name'
  printenv "$2" >/dev/null || fail "Unset variable: $2"
  if [[ $1 == --pass-env ]]; then PASS_ENV=$2; else OUT_PASS_ENV=$2; fi; shift 2;;
 --url)
  [[ $# -ge 2 && -n $2 ]] || fail 'Usage: --url URL'
  URL=$2; COMMAND=url; shift 2; break;;
 --legacy) LEGACY=1; shift;;
 --help|-h) usage; exit 0;;
 *) break;; esac
done
if [[ $COMMAND != url ]]; then
 [[ $# -gt 0 ]] || { usage; exit 2; }
 COMMAND=$1; shift
fi
[[ $COMMAND != -v ]] || COMMAND=verify
[[ $COMMAND != -x ]] || COMMAND=pfx-extract
[[ $COMMAND != -c ]] || COMMAND=pfx-create
[[ $COMMAND != -i ]] || COMMAND=inspect
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ssl-tool.XXXXXX")
PUBLISH_TMP=
cleanup() {
 [[ -z $PUBLISH_TMP ]] || rm -f -- "$PUBLISH_TMP"
 rm -rf -- "$TMP"
}
trap cleanup EXIT
P12_PASS_FILE=
read_p12_password() {
 [[ -n $PASS_ENV || -n $P12_PASS_FILE ]] && return 0
 local password
 if ! IFS= read -r -s -p 'Decrypt password: ' password </dev/tty; then
  fail 'Cannot read PFX password; use --pass-env for non-interactive use'
 fi
 printf '\n' >/dev/tty
 printf '%s\n' "$password" > "$TMP/p12-pass"
 unset password
 P12_PASS_FILE=$TMP/p12-pass
}
keycmd() {
 if [[ -n $PASS_ENV ]]; then openssl pkey "$@" -passin "env:$PASS_ENV"; else openssl pkey "$@"; fi
}
p12cmd() {
 local args=(pkcs12 "$@")
 if [[ -n $PASS_ENV ]]; then args+=(-passin "env:$PASS_ENV")
 elif [[ -n $P12_PASS_FILE ]]; then args+=(-passin "file:$P12_PASS_FILE"); fi
 [[ $LEGACY == 0 ]] || args+=(-legacy)
 openssl "${args[@]}"
}
p12out() {
 if [[ -n $OUT_PASS_ENV ]]; then p12cmd "$@" -passout "env:$OUT_PASS_ENV"; else p12cmd "$@"; fi
}
detect() {
 [[ -f $1 && -r $1 ]] || fail "Cannot read $1"
 KIND= FORMAT=PEM
 case $1 in *.pfx|*.p12|*.PFX|*.P12) KIND=pfx; FORMAT=DER; return 0;; esac
 if LC_ALL=C grep -aq -- '-----BEGIN CERTIFICATE-----' "$1"; then KIND=cert
 elif LC_ALL=C grep -aq -- 'CERTIFICATE REQUEST-----' "$1"; then KIND=csr
 elif LC_ALL=C grep -aq -- 'PRIVATE KEY-----' "$1"; then KIND=key
 elif LC_ALL=C grep -aq -- '-----BEGIN PKCS7-----' "$1"; then KIND=p7b
 else
  FORMAT=DER
  if openssl x509 -inform DER -in "$1" -noout >/dev/null 2>&1; then KIND=cert
  elif openssl req -inform DER -in "$1" -noout >/dev/null 2>&1; then KIND=csr
  elif openssl pkcs7 -inform DER -in "$1" -noout >/dev/null 2>&1; then KIND=p7b
  else KIND=key
  fi
 fi
}
certs() {
 local src=$1 dest=$2
 detect "$src" || fail "Cannot read $src"
 case $KIND in
 cert) if [[ $FORMAT == PEM ]]; then cat -- "$src" > "$dest"; else openssl x509 -inform DER -in "$src" -out "$dest"; fi;;
 pfx) p12cmd -in "$src" -nokeys > "$dest";;
 p7b) openssl pkcs7 -inform "$FORMAT" -in "$src" -print_certs > "$dest";;
 *) fail 'Expected certificate, PKCS7 or PFX';; esac
 grep -q -- '-----BEGIN CERTIFICATE-----' "$dest" || fail 'No certificate found'
}
load_certs() {
 local src=$1 dest=$2
 [[ -f $src && -r $src ]] || return 1
 detect "$src" || return 1
 case $KIND in
 cert) if [[ $FORMAT == PEM ]]; then cat -- "$src" > "$dest" || return 1
  else openssl x509 -inform DER -in "$src" -out "$dest" || return 1; fi;;
 pfx) p12cmd -in "$src" -nokeys > "$dest" || return 1;;
 p7b) openssl pkcs7 -inform "$FORMAT" -in "$src" -print_certs > "$dest" || return 1;;
 *) return 2;;
 esac
 grep -q -- '-----BEGIN CERTIFICATE-----' "$dest"
}
split_certs() {
 local src=$1 prefix=$2
 SPLIT_COUNT=$(grep -ac -- '-----BEGIN CERTIFICATE-----' "$src") || return 1
 [[ $SPLIT_COUNT -gt 0 ]] || return 1
 awk -v dir="$TMP" -v prefix="$prefix" '
  /-----BEGIN CERTIFICATE-----/ { n++; f=sprintf("%s/%s-%04d.pem",dir,prefix,n) }
  f!="" { print > f }
  /-----END CERTIFICATE-----/ { close(f); f="" }
 ' "$src" || return 1
}
is_ca_cert() {
 if openssl x509 -in "$1" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then
  CERT_IS_CA=1
 else
  CERT_IS_CA=0
 fi
}
print_cert_details() {
 local cert=$1 label=$2 details san fingerprint
 if ! details=$(openssl x509 -in "$cert" -noout -subject -issuer -serial -startdate -enddate -nameopt RFC2253); then
  return 1
 fi
 printf '[CERT] %s\n' "$label"
 printf '%s\n' "$details" | sed \
  -e 's/^subject=/  Subject: /' \
  -e 's/^issuer=/  Issuer \/ CA (provider): /' \
  -e 's/^serial=/  Serial: /' \
  -e 's/^notBefore=/  Valid from: /' \
  -e 's/^notAfter=/  Expires: /'
 if san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null); then
  printf '  Subject alternative names:\n'
  printf '%s\n' "$san" | awk '
   NR > 1 {
    gsub(/^[ \t]+/, "")
    n = split($0, entries, /, */)
    for (i = 1; i <= n; i++) if (entries[i] != "") printf "    %s\n", entries[i]
   }
  '
 else
  printf '  Subject alternative names: (none)\n'
 fi
 fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -md5) || return 1
 printf '  MD5 fingerprint: %s\n' "${fingerprint#*=}"
}
verify_target() {
 local target=$1 source prefix cert index cert_hash key_hash hash_index
 local skipped=0 scan_failures=0 file_count=0
 local -a verify_files=() verify_certs=() verify_ca=()
 local -a key_files=() key_hashes=() key_matched=()
 local -a hash_files=() hash_values=()
 : > "$TMP/directory-certs.pem"
 if [[ -d $target ]]; then
  find "$target" -type f -print0 > "$TMP/scan-files" || fail "Cannot scan directory: $target"
  while IFS= read -r -d '' source; do
   file_count=$((file_count + 1))
   if [[ ! -r $source ]]; then
    printf '[FAIL] %s: file is not readable\n' "$source"
    scan_failures=$((scan_failures + 1))
    continue
   fi
   KIND=
   if ! detect "$source"; then
    printf '[FAIL] %s: cannot read file\n' "$source"
    scan_failures=$((scan_failures + 1))
    continue
   fi
   case $KIND in
   cert|pfx|p7b) ;;
   key)
    if key_hash=$(pubhash "$source"); then
     key_files+=("$source")
     key_hashes+=("$key_hash")
     key_matched+=(0)
     hash_files+=("${source##*/}")
     hash_values+=("$key_hash")
    else
     printf '[FAIL] %s: cannot parse private key or read its public key\n' "$source"
     scan_failures=$((scan_failures + 1))
    fi
    continue;;
   *)
    case $source in
    *.crt|*.CRT|*.cer|*.CER|*.der|*.DER|*.p7b|*.P7B|*.pfx|*.PFX|*.p12|*.P12)
     printf '[FAIL] %s: invalid or unsupported certificate file\n' "$source"
     scan_failures=$((scan_failures + 1));;
    *) printf '[SKIP] %s: not a supported certificate file\n' "$source"; skipped=$((skipped + 1));;
    esac
    continue;;
   esac
   [[ $KIND != pfx ]] || read_p12_password
   prefix=scan-$file_count
   if ! load_certs "$source" "$TMP/$prefix.pem"; then
    printf '[FAIL] %s: cannot extract certificates\n' "$source"
    scan_failures=$((scan_failures + 1))
    continue
   fi
   if ! split_certs "$TMP/$prefix.pem" "$prefix"; then
    printf '[FAIL] %s: no readable certificates found\n' "$source"
    scan_failures=$((scan_failures + 1))
    continue
   fi
   index=0
   for cert in "$TMP/$prefix"-*.pem; do
    [[ -f $cert ]] || continue
    index=$((index + 1))
    if [[ $index == 1 ]]; then
     cert_hash=$(pubhash "$cert") || {
      printf '[FAIL] %s: cannot read certificate public key\n' "$source"
      scan_failures=$((scan_failures + 1))
      continue
     }
     hash_files+=("${source##*/}")
     hash_values+=("$cert_hash")
    fi
    is_ca_cert "$cert"
    verify_files+=("$source")
    verify_certs+=("$cert")
    verify_ca+=("$CERT_IS_CA")
    cat -- "$cert" >> "$TMP/directory-certs.pem"
   done
  done < "$TMP/scan-files"
 else
  [[ -f $target && -r $target ]] || fail "Cannot read certificate file or directory: $target"
  detect "$target" || fail "Cannot read $target"
  [[ $KIND != pfx ]] || read_p12_password
  load_certs "$target" "$TMP/input.pem" || fail "Cannot extract certificates from $target"
  split_certs "$TMP/input.pem" input || fail "No readable certificates found in $target"
  index=0
  for cert in "$TMP"/input-*.pem; do
   [[ -f $cert ]] || continue
   index=$((index + 1))
   if [[ $index == 1 ]]; then
    cert_hash=$(pubhash "$cert") || fail "Cannot read certificate public key: $target"
    hash_files+=("${target##*/}")
    hash_values+=("$cert_hash")
   fi
   is_ca_cert "$cert"
   verify_files+=("$target")
   verify_certs+=("$cert")
   verify_ca+=("$CERT_IS_CA")
   cat -- "$cert" >> "$TMP/directory-certs.pem"
  done
 fi
 if [[ ${#verify_certs[@]} -eq 0 ]]; then
  printf 'Summary: 0 certificate(s) passed, %d failed, %d unsupported file(s) skipped.\n' "$scan_failures" "$skipped"
  fail "No supported certificates found in $target"
 fi
 local passed=0 failed=$scan_failures purpose label file_passed file_failed file_total cert_number key_index
 index=0
 while [[ $index -lt ${#verify_certs[@]} ]]; do
  source=${verify_files[$index]}
  file_passed=0; file_failed=0; file_total=0; cert_number=0
  while [[ $index -lt ${#verify_certs[@]} && ${verify_files[$index]} == "$source" ]]; do
   cert_number=$((cert_number + 1))
   file_total=$((file_total + 1))
   label="$source (certificate $cert_number)"
   if ! print_cert_details "${verify_certs[$index]}" "$label"; then
    printf '[FAIL] %s: cannot read certificate details\n' "$label"
    file_failed=$((file_failed + 1))
    failed=$((failed + 1))
    index=$((index + 1))
    continue
   fi
   cert_hash=$(pubhash "${verify_certs[$index]}") || {
    printf '[FAIL] %s: cannot read certificate public key\n' "$label"
    file_failed=$((file_failed + 1))
    failed=$((failed + 1))
    index=$((index + 1))
    continue
   }
   for key_index in "${!key_files[@]}"; do
    if [[ ${key_hashes[$key_index]} == "$cert_hash" ]]; then
     printf '  [MATCH] private key: %s\n' "${key_files[$key_index]}"
     key_matched[$key_index]=1
    fi
   done
   purpose=sslserver
   [[ ${verify_ca[$index]} == 0 ]] || purpose=any
   ARGS=(verify -purpose "$purpose" -untrusted "$TMP/directory-certs.pem")
   if openssl "${ARGS[@]}" "${verify_certs[$index]}" > "$TMP/verify-output" 2>&1; then
    file_passed=$((file_passed + 1))
    passed=$((passed + 1))
   else
    cat -- "$TMP/verify-output" >&2
    file_failed=$((file_failed + 1))
    failed=$((failed + 1))
   fi
   index=$((index + 1))
  done
  if [[ $file_failed == 0 ]]; then
   printf '[PASS] %s (%d/%d certificates)\n' "$source" "$file_passed" "$file_total"
  else
   printf '[FAIL] %s (%d/%d certificates passed)\n' "$source" "$file_passed" "$file_total"
  fi
 done
 for hash_index in "${!hash_files[@]}"; do
  printf '%s  %s\n' "${hash_values[$hash_index]}" "${hash_files[$hash_index]}"
 done
 for key_index in "${!key_files[@]}"; do
  if [[ ${key_matched[$key_index]} == 0 ]]; then
   printf '[MISMATCH] %s: no matching certificate found\n' "${key_files[$key_index]}"
   failed=$((failed + 1))
  fi
 done
 printf 'Summary: %d certificate(s) passed, %d failed, %d unsupported file(s) skipped.\n' "$passed" "$failed" "$skipped"
 [[ $failed == 0 ]]
}
pubhash() {
 detect "$1"
 case $KIND in
 cert) openssl x509 -inform "$FORMAT" -in "$1" -pubkey -noout > "$TMP/pub.pem" || return 1;;
 csr) openssl req -inform "$FORMAT" -in "$1" -pubkey -noout > "$TMP/pub.pem" || return 1;;
 key) keycmd -inform "$FORMAT" -in "$1" -pubout > "$TMP/pub.pem" || return 1;;
 pfx) certs "$1" "$TMP/pfx-certs.pem" || return 1; openssl x509 -in "$TMP/pfx-certs.pem" -pubkey -noout > "$TMP/pub.pem" || return 1;;
 *) fail 'Unsupported match input';; esac
 openssl pkey -pubin -in "$TMP/pub.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}'
}
publish() {
 (set -o noclobber; cat -- "$1" > "$2") || fail "Cannot create output: $2"
 chmod 600 "$2"
}
publish_replace() {
 local staged
 [[ ! -d $2 ]] || fail "Output path is a directory: $2"
 staged=$(mktemp "$DEST/.ssl-tool.XXXXXX") || fail "Cannot stage output in $DEST"
 PUBLISH_TMP=$staged
 cat -- "$1" > "$staged" || fail "Cannot stage output: $2"
 chmod 600 "$staged" || fail "Cannot set output permissions: $2"
 mv -f -- "$staged" "$2" || fail "Cannot replace output: $2"
 PUBLISH_TMP=
}
case $COMMAND in
url)
 command -v curl >/dev/null || fail 'curl required for --url'
 if curl -ivk --url "$URL" -o /dev/null 2>"$TMP/curl.log"; then
  CURL_STATUS=0
 else
  CURL_STATUS=$?
 fi
 if ! awk '
  /^\* Server certificate:/ { printing=1; found=1; print; next }
  printing {
   if ($0 ~ /^\*  (subject|start date|expire date|issuer):/ ||
       $0 ~ /^\* .*certificate verify result:/ ||
       $0 ~ /^\*   Certificate level [0-9]+:/) print
   else exit
  }
  END { if (!found) exit 1 }
 ' "$TMP/curl.log"; then
  fail "curl did not return a Server certificate section (exit code $CURL_STATUS)"
 fi
 [[ $CURL_STATUS == 0 ]] || fail "curl failed after returning the server certificate (exit code $CURL_STATUS)"
 ;;
inspect)
 [[ $# -ge 1 && $# -le 2 ]] || fail 'inspect FILE [-t]'
 FILE=$1; TEXT=0
 if [[ $# == 2 ]]; then [[ $2 == -t || $2 == --text ]] || fail 'Unknown option'; TEXT=1; fi
 detect "$FILE"; printf 'Type: %s; encoding: %s\n' "$KIND" "$FORMAT"
 case $KIND in
 cert|pfx|p7b)
  certs "$FILE" "$TMP/certs.pem"
  awk -v dir="$TMP" '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s/cert-%04d.pem",dir,n)} f!=""{print > f} /-----END CERTIFICATE-----/{close(f); f=""}' "$TMP/certs.pem"
  for c in "$TMP"/cert-*.pem; do
   printf '\n=== %s ===\n' "${c##*/}"
   if [[ $TEXT == 1 ]]; then openssl x509 -in "$c" -noout -text
   else openssl x509 -in "$c" -noout -subject -issuer -serial -dates -fingerprint -sha256 -ext subjectAltName,basicConstraints,keyUsage,extendedKeyUsage; fi
  done
  echo 'Inspection does not establish trust; use verify.';;
 csr) openssl req -in "$FILE" -inform "$FORMAT" -verify -noout -text; echo 'CSR has no validity dates or issuing CA.';;
 key) keycmd -in "$FILE" -inform "$FORMAT" -check -noout
  keycmd -in "$FILE" -inform "$FORMAT" -pubout > "$TMP/key-public.pem"
  openssl pkey -pubin -in "$TMP/key-public.pem" -text -noout
  openssl pkey -pubin -in "$TMP/key-public.pem" -outform DER | openssl dgst -sha256;; esac;;
verify)
 TARGET=
 while [[ $# -gt 0 ]]; do
  case $1 in
  -d) [[ $# -ge 2 && -z $TARGET ]] || fail 'Provide one directory after -d'; TARGET=$2; shift 2;;
  --chain|--ca|--hostname) fail "$1 is no longer supported; verify uses the system trust store and checks certificate validity";;
  -*) fail "Unknown verify option: $1";;
  *) [[ -z $TARGET ]] || fail 'Provide one certificate or directory'; TARGET=$1; shift;;
  esac
 done
 [[ -n $TARGET ]] || fail 'Usage: verify CERT | verify -d DIR'
 verify_target "$TARGET";;
pfx-extract)
 [[ $# -ge 1 ]] || fail 'Missing PFX'
 FILE=$1; shift; DEST=
 while [[ $# -gt 0 ]]; do
  case $1 in
  -d|--out-dir) [[ $# -ge 2 ]] || fail 'Missing directory'; DEST=$2; shift 2;;
  *) fail "Unknown option $1";; esac
 done
 [[ -n $DEST ]] || fail 'Missing -d/--out-dir'
 if [[ -e $DEST || -L $DEST ]]; then
  [[ -d $DEST ]] || fail 'Output path exists and is not a directory'
  for output in server.crt chain.crt fullchain.crt; do
   [[ ! -d $DEST/$output ]] || fail "Output path is a directory: $DEST/$output"
  done
  [[ ! -d $DEST/leaf.crt ]] || fail "Output path is a directory: $DEST/leaf.crt"
  [[ ! -d $DEST/private.key ]] || fail "Output path is a directory: $DEST/private.key"
 else
  DEST_NEW=1
 fi
 read_p12_password
 p12cmd -in "$FILE" -clcerts -nokeys > "$TMP/server.crt"
 p12cmd -in "$FILE" -cacerts -nokeys > "$TMP/chain.crt"
 cat -- "$TMP/server.crt" "$TMP/chain.crt" > "$TMP/fullchain.crt"
 p12cmd -in "$FILE" -nocerts -nodes > "$TMP/private.key"
 grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$TMP/private.key" || fail 'No private key found in PFX'
 [[ ${DEST_NEW:-0} == 0 ]] || mkdir -m 700 -- "$DEST"
 publish_replace "$TMP/server.crt" "$DEST/server.crt"
 publish_replace "$TMP/chain.crt" "$DEST/chain.crt"
 publish_replace "$TMP/fullchain.crt" "$DEST/fullchain.crt"
 publish_replace "$TMP/private.key" "$DEST/private.key"
 [[ ! -f $DEST/leaf.crt && ! -L $DEST/leaf.crt ]] || rm -f -- "$DEST/leaf.crt"
 [[ ! -f $DEST/leaf.crt && ! -L $DEST/leaf.crt ]] || rm -f -- "$DEST/leaf.crt"
 echo "Extracted to $DEST; chain may be empty.";;
pfx-create)
 SOURCE_DIR=; OUT=
 while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'Missing option value'
  case $1 in -d) SOURCE_DIR=$2;; -o|--out) OUT=$2;; *) fail "Unknown option $1";; esac; shift 2
 done
 [[ -n $SOURCE_DIR && -d $SOURCE_DIR && -r $SOURCE_DIR ]] || fail 'Requires -d DIR (readable directory)'
 [[ -n $OUT && ! -e $OUT ]] || fail 'Requires -o NEW_FILE (output must not exist)'
 find "$SOURCE_DIR" -type f -print0 > "$TMP/create-files" || fail "Cannot scan directory: $SOURCE_DIR"
 CREATE_CERTS=() CREATE_CERT_HASHES=() CREATE_KEYS=() CREATE_KEY_HASHES=()
 source= cert_file= key_file= key_hash= file_count=0 cert_hash= match_index=-1 match_count=0 index= duplicate=0
 while IFS= read -r -d '' source; do
  file_count=$((file_count + 1))
  if [[ ! -r $source ]]; then
   printf '[SKIP] unreadable file: %s\n' "$source" >&2
   continue
  fi
  if [[ ! -s $source ]]; then
   printf '[SKIP] empty file: %s\n' "$source" >&2
   continue
  fi
  if ! detect "$source"; then
   printf '[SKIP] unsupported file: %s\n' "$source" >&2
   continue
  fi
  case $KIND in
  cert|p7b)
   if load_certs "$source" "$TMP/create-source-$file_count.pem" &&
      split_certs "$TMP/create-source-$file_count.pem" "create-$file_count"; then
    for cert_file in "$TMP"/create-"$file_count"-*.pem; do
     [[ -f $cert_file ]] || continue
     cert_hash=$(pubhash "$cert_file") || fail "Invalid certificate: $source"
     duplicate=0
     for index in "${!CREATE_CERTS[@]}"; do
      if [[ ${CREATE_CERT_HASHES[$index]} == "$cert_hash" ]]; then duplicate=1; break; fi
     done
     if [[ $duplicate == 0 ]]; then
      CREATE_CERTS+=("$cert_file")
      CREATE_CERT_HASHES+=("$cert_hash")
     fi
    done
   else
    case $source in *.crt|*.CRT|*.cer|*.CER|*.der|*.DER|*.p7b|*.P7B)
     fail "Invalid certificate input: $source";;
    esac
   fi;;
  key)
   if keycmd -inform "$FORMAT" -in "$source" -check -out "$TMP/create-key-$file_count.pem" >/dev/null &&
      grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$TMP/create-key-$file_count.pem"; then
    CREATE_KEYS+=("$TMP/create-key-$file_count.pem")
    key_hash=$(pubhash "$TMP/create-key-$file_count.pem") || fail "Cannot read private key: $source"
    CREATE_KEY_HASHES+=("$key_hash")
   else
    case $source in
    *.crt|*.CRT|*.cer|*.CER|*.der|*.DER|*.p7b|*.P7B)
     fail "Invalid certificate input: $source";;
    *.key|*.KEY) fail "Invalid private key: $source";;
    esac
   fi;;
  esac
 done < "$TMP/create-files"
 [[ ${#CREATE_KEYS[@]} == 1 ]] || fail "Expected exactly one valid private key in $SOURCE_DIR; found ${#CREATE_KEYS[@]}"
 [[ ${#CREATE_CERTS[@]} -gt 0 ]] || fail "No X.509 certificates found in $SOURCE_DIR"
 key_file=${CREATE_KEYS[0]}
 key_hash=${CREATE_KEY_HASHES[0]}
 for index in "${!CREATE_CERTS[@]}"; do
  cert_file=${CREATE_CERTS[$index]}
  cert_hash=${CREATE_CERT_HASHES[$index]}
  if [[ $cert_hash == "$key_hash" ]]; then
   match_index=$index
   match_count=$((match_count + 1))
  fi
 done
 [[ $match_count == 1 ]] || fail "Expected exactly one certificate matching the private key; found $match_count"
 cat -- "${CREATE_CERTS[$match_index]}" > "$TMP/create-leaf.pem"
 : > "$TMP/create-chain.pem"
 for index in "${!CREATE_CERTS[@]}"; do
  [[ $index == "$match_index" ]] || cat -- "${CREATE_CERTS[$index]}" >> "$TMP/create-chain.pem"
 done
 ARGS=(-export -in "$TMP/create-leaf.pem" -inkey "$key_file")
 [[ ! -s $TMP/create-chain.pem ]] || ARGS+=(-certfile "$TMP/create-chain.pem")
 p12out "${ARGS[@]}" > "$TMP/result.pfx"
 publish "$TMP/result.pfx" "$OUT"; echo "Created $OUT";;
convert)
 [[ $# -ge 1 ]] || fail 'Missing input'
 FILE=$1; shift; OUT=; TARGET=
 while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'Missing option value'
  case $1 in -f|--format) TARGET=$2;; -o|--out) OUT=$2;; *) fail "Unknown option $1";; esac; shift 2
 done
 [[ -n $OUT && ! -e $OUT ]] || fail 'Output must be new'
 [[ $TARGET == PEM || $TARGET == DER ]] || fail 'Format must be PEM or DER'
 detect "$FILE"
 case $KIND in
 cert)
  if [[ $FORMAT == PEM ]]; then
   COUNT=$(grep -ac -- '-----BEGIN CERTIFICATE-----' "$FILE")
   [[ $COUNT == 1 ]] || fail 'Convert one certificate at a time, not fullchain'
  fi
  openssl x509 -in "$FILE" -inform "$FORMAT" -outform "$TARGET" > "$TMP/converted";;
 csr) openssl req -in "$FILE" -inform "$FORMAT" -outform "$TARGET" > "$TMP/converted";;
 *) fail 'convert supports certificate/CSR only';; esac
 publish "$TMP/converted" "$OUT";;
*) usage; exit 2;;
esac
