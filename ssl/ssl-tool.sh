#!/usr/bin/env bash
# OpenSSL certificate inspection and conversion; Bash 3.2+.
set -Eeuo pipefail
trap 'exit 1' ERR
umask 077
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
 cat <<'HELP'
Usage: ssl-tool.sh [--pass-env NAME] [--out-pass-env NAME] [--legacy] COMMAND
  inspect FILE [--text]
  match FILE FILE [FILE...]
  verify CERT [--chain FILE] [--ca FILE] [--hostname DNS]
  pfx-extract FILE --out-dir NEW_DIR [--include-key] [--unencrypted-key]
  pfx-create --cert FILE --key FILE [--chain FILE] --out NEW_FILE
  convert FILE --format PEM|DER --out NEW_FILE
Passwords are prompted by OpenSSL unless environment variable names are supplied.
HELP
}
command -v openssl >/dev/null || fail 'openssl is required'
PASS_ENV= OUT_PASS_ENV= LEGACY=0
while [[ $# -gt 0 ]]; do
 case $1 in
 --pass-env|--out-pass-env)
  [[ $# -ge 2 ]] || fail 'Missing environment variable name'
  [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail 'Invalid environment variable name'
  printenv "$2" >/dev/null || fail "Environment variable unset: $2"
  if [[ $1 == --pass-env ]]; then PASS_ENV=$2; else OUT_PASS_ENV=$2; fi
  shift 2;;
 --legacy) LEGACY=1; shift;;
 --help|-h) usage; exit 0;;
 *) break;;
 esac
done
[[ $# -gt 0 ]] || { usage; exit 2; }
COMMAND=$1; shift
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ssl-tool.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
# Wrappers avoid empty-array expansion issues with Bash 3.2 + nounset.
keycmd() {
 if [[ -n $PASS_ENV ]]; then openssl pkey "$@" -passin "env:$PASS_ENV"; else openssl pkey "$@"; fi
}
p12cmd() {
 local args=(pkcs12 "$@")
 [[ -z $PASS_ENV ]] || args+=(-passin "env:$PASS_ENV")
 [[ $LEGACY == 0 ]] || args+=(-legacy)
 openssl "${args[@]}"
}
p12out() {
 if [[ -n $OUT_PASS_ENV ]]; then p12cmd "$@" -passout "env:$OUT_PASS_ENV"; else p12cmd "$@"; fi
}
detect() {
 [[ -f $1 && -r $1 ]] || fail "Cannot read $1"
 KIND= FORMAT=PEM
 if LC_ALL=C grep -aq -- '-----BEGIN CERTIFICATE-----' "$1"; then KIND=cert
 elif LC_ALL=C grep -aq -- 'CERTIFICATE REQUEST-----' "$1"; then KIND=csr
 elif LC_ALL=C grep -aq -- 'PRIVATE KEY-----' "$1"; then KIND=key
 elif LC_ALL=C grep -aq -- '-----BEGIN PKCS7-----' "$1"; then KIND=p7b
 else
  FORMAT=DER
  if openssl x509 -inform DER -in "$1" -noout >/dev/null 2>&1; then KIND=cert
  elif openssl req -inform DER -in "$1" -noout >/dev/null 2>&1; then KIND=csr
  elif openssl pkcs7 -inform DER -in "$1" -noout >/dev/null 2>&1; then KIND=p7b
  else
   case $1 in *.pfx|*.p12|*.PFX|*.P12) KIND=pfx;; *) KIND=key;; esac
  fi
 fi
}
certs() {
 local src=$1 dest=$2
 detect "$src"
 case $KIND in
 cert) if [[ $FORMAT == PEM ]]; then cat -- "$src" > "$dest"; else openssl x509 -inform DER -in "$src" -out "$dest"; fi;;
 pfx) p12cmd -in "$src" -nokeys > "$dest";;
 p7b) openssl pkcs7 -inform "$FORMAT" -in "$src" -print_certs > "$dest";;
 *) fail 'Expected certificate, PKCS#7 or PFX';;
 esac
 grep -q -- '-----BEGIN CERTIFICATE-----' "$dest" || fail 'No certificate found'
}
pubhash() {
 local src=$1
 detect "$src"
 case $KIND in
 cert) openssl x509 -inform "$FORMAT" -in "$src" -pubkey -noout > "$TMP/pub.pem" || return 1;;
 csr) openssl req -inform "$FORMAT" -in "$src" -pubkey -noout > "$TMP/pub.pem" || return 1;;
 key) keycmd -inform "$FORMAT" -in "$src" -pubout > "$TMP/pub.pem" || return 1;;
 pfx) certs "$src" "$TMP/pfx-certs.pem"; openssl x509 -in "$TMP/pfx-certs.pem" -pubkey -noout > "$TMP/pub.pem" || return 1;;
 *) fail 'match accepts certificate, CSR, private key or PFX certificate';;
 esac
 openssl pkey -pubin -in "$TMP/pub.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}'
}
publish() {
 # noclobber protects against accidental overwrite, including concurrent creation.
 (set -o noclobber; cat -- "$1" > "$2") || fail "Cannot create output (already exists?): $2"
 chmod 600 "$2"
}
case $COMMAND in
inspect)
 [[ $# -ge 1 && $# -le 2 ]] || fail 'inspect FILE [--text]'
 FILE=$1; TEXT=0
 if [[ $# == 2 ]]; then [[ $2 == --text ]] || fail 'Unknown inspect option'; TEXT=1; fi
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
  openssl pkey -pubin -in "$TMP/key-public.pem" -outform DER | openssl dgst -sha256;;
 esac;;
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
 [[ $# -ge 1 ]] || fail 'verify requires certificate'
 FILE=$1; shift; CHAIN=; CA=; HOST=
 while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'Missing option value'
  case $1 in --chain) CHAIN=$2;; --ca) CA=$2;; --hostname) HOST=$2;; *) fail "Unknown option $1";; esac; shift 2
 done
 certs "$FILE" "$TMP/all.pem"
 awk '/-----BEGIN CERTIFICATE-----/{n++} n==1{print} /-----END CERTIFICATE-----/ && n==1{exit}' "$TMP/all.pem" > "$TMP/leaf.pem"
 awk '/-----BEGIN CERTIFICATE-----/{n++} n>1{print}' "$TMP/all.pem" > "$TMP/chain.pem"
 if [[ -n $CHAIN ]]; then certs "$CHAIN" "$TMP/extra.pem"; cat "$TMP/extra.pem" >> "$TMP/chain.pem"; fi
 ARGS=(verify -purpose sslserver)
 [[ ! -s $TMP/chain.pem ]] || ARGS+=(-untrusted "$TMP/chain.pem")
 [[ -z $CA ]] || ARGS+=(-CAfile "$CA")
 [[ -z $HOST ]] || ARGS+=(-verify_hostname "$HOST")
 openssl "${ARGS[@]}" "$TMP/leaf.pem";;
pfx-extract)
 [[ $# -ge 1 ]] || fail 'pfx-extract requires input'
 FILE=$1; shift; DEST=; INCLUDE=0; PLAIN=0
 while [[ $# -gt 0 ]]; do
  case $1 in
  --out-dir) [[ $# -ge 2 ]] || fail 'Missing directory'; DEST=$2; shift 2;;
  --include-key) INCLUDE=1; shift;; --unencrypted-key) PLAIN=1; shift;;
  *) fail "Unknown option $1";; esac
 done
 [[ -n $DEST && ! -e $DEST ]] || fail 'Output directory must be new'
 [[ $PLAIN == 0 || $INCLUDE == 1 ]] || fail '--unencrypted-key requires --include-key'
 p12cmd -in "$FILE" -clcerts -nokeys > "$TMP/leaf.crt"
 p12cmd -in "$FILE" -cacerts -nokeys > "$TMP/chain.crt"
 if [[ $INCLUDE == 1 ]]; then
  if [[ $PLAIN == 1 ]]; then p12cmd -in "$FILE" -nocerts -nodes > "$TMP/private.key"
  else p12out -in "$FILE" -nocerts > "$TMP/private.key"; fi
 fi
 mkdir -m 700 -- "$DEST"
 publish "$TMP/leaf.crt" "$DEST/leaf.crt"; publish "$TMP/chain.crt" "$DEST/chain.crt"
 [[ $INCLUDE == 0 ]] || publish "$TMP/private.key" "$DEST/private.key"
 echo "Extracted to $DEST; chain may be empty.";;
pfx-create)
 CERT=; KEY=; CHAIN=; OUT=
 while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'Missing option value'
  case $1 in --cert) CERT=$2;; --key) KEY=$2;; --chain) CHAIN=$2;; --out) OUT=$2;; *) fail "Unknown option $1";; esac; shift 2
 done
 [[ -n $CERT && -n $KEY && -n $OUT && ! -e $OUT ]] || fail 'Requires --cert --key --out (new file)'
 A=$(pubhash "$CERT") || fail 'Invalid certificate'; B=$(pubhash "$KEY") || fail 'Invalid key'
 [[ $A == "$B" ]] || fail 'Certificate/key mismatch'
 ARGS=(-export -in "$CERT" -inkey "$KEY")
 [[ -z $CHAIN ]] || ARGS+=(-certfile "$CHAIN")
 p12out "${ARGS[@]}" > "$TMP/result.pfx"
 publish "$TMP/result.pfx" "$OUT"; echo "Created $OUT";;
convert)
 [[ $# -ge 1 ]] || fail 'convert requires input'
 FILE=$1; shift; OUT=; TARGET=
 while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'Missing option value'
  case $1 in --format) TARGET=$2;; --out) OUT=$2;; *) fail "Unknown option $1";; esac; shift 2
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
 *) fail 'convert supports certificate/CSR only';;
 esac
 publish "$TMP/converted" "$OUT";;
*) usage; exit 2;;
esac
