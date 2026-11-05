#!/usr/bin/env bash
# Certificate inspection/conversion with Bash 3.2+ and OpenSSL.
set -Eeuo pipefail
trap 'exit 1' ERR
umask 077
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
 cat <<'HELP'
Usage: ssl-tool.sh [--pass-env NAME] [--out-pass-env NAME] [--legacy] COMMAND
  inspect FILE [-t]
  match FILE FILE [FILE...]
  verify CERT | verify -d DIR | -v -d DIR
  pfx-extract FILE -d DIR [-k] [-u]
  pfx-create --cert FILE --key FILE [--chain FILE] -o NEW_FILE
  convert FILE -f PEM|DER -o NEW_FILE
  -k includes the private key; -u exports it unencrypted.
  -d, -k, -u, -o, -t, and -f are short forms; long forms remain supported.
Passwords are prompted unless environment variable names are supplied.
HELP
}
command -v openssl >/dev/null || fail 'openssl required'
PASS_ENV= OUT_PASS_ENV= LEGACY=0
while [[ $# -gt 0 ]]; do
 case $1 in
 --pass-env|--out-pass-env)
  [[ $# -ge 2 ]] || fail 'Missing variable name'
  [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail 'Invalid variable name'
  printenv "$2" >/dev/null || fail "Unset variable: $2"
  if [[ $1 == --pass-env ]]; then PASS_ENV=$2; else OUT_PASS_ENV=$2; fi; shift 2;;
 --legacy) LEGACY=1; shift;;
 --help|-h) usage; exit 0;;
 *) break;; esac
done
[[ $# -gt 0 ]] || { usage; exit 2; }
COMMAND=$1; shift
[[ $COMMAND != -v ]] || COMMAND=verify
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
 local cert=$1 label=$2 details san
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
}
verify_target() {
 local target=$1 source prefix cert index
 local skipped=0 scan_failures=0 file_count=0
 local -a verify_files=() verify_certs=() verify_ca=()
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
   case $KIND in cert|pfx|p7b) ;;
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
 local passed=0 failed=$scan_failures purpose label file_passed file_failed file_total cert_number
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
match)
 [[ $# -ge 2 ]] || fail 'Provide at least two files'
 FIRST=; SAME=1
 for f in "$@"; do
  HASH=$(pubhash "$f") || fail "Cannot parse $f"
  printf '%s  %s\n' "$HASH" "$f"
  if [[ -z $FIRST ]]; then FIRST=$HASH; elif [[ $HASH != "$FIRST" ]]; then SAME=0; fi
 done
 [[ $SAME == 1 ]] || { echo MISMATCH; exit 1; }; echo MATCH;;
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
 FILE=$1; shift; DEST=; INCLUDE=0; PLAIN=0
 while [[ $# -gt 0 ]]; do
  case $1 in
  -d|--out-dir) [[ $# -ge 2 ]] || fail 'Missing directory'; DEST=$2; shift 2;;
  -k|--include-key) INCLUDE=1; shift;; -u|--unencrypted-key) PLAIN=1; shift;;
  *) fail "Unknown option $1";; esac
 done
 [[ -n $DEST ]] || fail 'Missing -d/--out-dir'
 [[ $PLAIN == 0 || $INCLUDE == 1 ]] || fail '-u/--unencrypted-key requires -k/--include-key'
 if [[ -e $DEST || -L $DEST ]]; then
  [[ -d $DEST ]] || fail 'Output path exists and is not a directory'
  for output in leaf.crt chain.crt; do
   [[ ! -d $DEST/$output ]] || fail "Output path is a directory: $DEST/$output"
  done
  if [[ $INCLUDE == 1 ]]; then
   [[ ! -d $DEST/private.key ]] || fail "Output path is a directory: $DEST/private.key"
  fi
 else
  DEST_NEW=1
 fi
 read_p12_password
 p12cmd -in "$FILE" -clcerts -nokeys > "$TMP/leaf.crt"
 p12cmd -in "$FILE" -cacerts -nokeys > "$TMP/chain.crt"
 if [[ $INCLUDE == 1 ]]; then
  if [[ $PLAIN == 1 ]]; then p12cmd -in "$FILE" -nocerts -nodes > "$TMP/private.key"
  else p12out -in "$FILE" -nocerts > "$TMP/private.key"; fi
 fi
 [[ ${DEST_NEW:-0} == 0 ]] || mkdir -m 700 -- "$DEST"
 publish_replace "$TMP/leaf.crt" "$DEST/leaf.crt"; publish_replace "$TMP/chain.crt" "$DEST/chain.crt"
 [[ $INCLUDE == 0 ]] || publish_replace "$TMP/private.key" "$DEST/private.key"
 echo "Extracted to $DEST; chain may be empty.";;
pfx-create)
 CERT=; KEY=; CHAIN=; OUT=
 while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'Missing option value'
  case $1 in --cert) CERT=$2;; --key) KEY=$2;; --chain) CHAIN=$2;; -o|--out) OUT=$2;; *) fail "Unknown option $1";; esac; shift 2
 done
 [[ -n $CERT && -n $KEY && -n $OUT && ! -e $OUT ]] || fail 'Requires --cert --key -o/--out (new file)'
 A=$(pubhash "$CERT") || fail 'Invalid certificate'; B=$(pubhash "$KEY") || fail 'Invalid key'
 [[ $A == "$B" ]] || fail 'Certificate/key mismatch'
 ARGS=(-export -in "$CERT" -inkey "$KEY")
 [[ -z $CHAIN ]] || ARGS+=(-certfile "$CHAIN")
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
