#!/usr/bin/env bash
set -u

usage() {
  echo "用法：$0 [--ca 憑證檔] https://主機[:URL連接埠][/路徑] [連接埠]"
  echo "  若未指定連接埠，預設使用網址中的連接埠；若網址也未指定，則使用 443。"
}

ca_file=""
args=()

while (($#)); do
  case "$1" in
    --ca)
      (($# >= 2)) || { usage >&2; exit 2; }
      ca_file=$2
      shift 2
      ;;
    --ca=*)
      ca_file=${1#--ca=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "錯誤：未知選項：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if ((${#args[@]} < 1 || ${#args[@]} > 2)); then
  usage >&2
  exit 2
fi

url=${args[0]}
port=${args[1]:-}

[[ "$url" == https://* ]] || {
  echo "錯誤：網址必須以 https:// 開頭" >&2
  exit 2
}

if [[ -n "$ca_file" && ! -r "$ca_file" ]]; then
  echo "錯誤：無法讀取 CA 憑證檔：$ca_file" >&2
  exit 2
fi

if [[ -n "$port" ]]; then
  [[ "$port" =~ ^[0-9]+$ ]] || {
    echo "錯誤：連接埠必須是 1 到 65535 之間的數字" >&2
    exit 2
  }
  port_num=$((10#${port}))
  ((port_num >= 1 && port_num <= 65535)) || {
    echo "錯誤：連接埠必須介於 1 到 65535" >&2
    exit 2
  }
  port=$port_num
fi

authority=${url#https://}
authority=${authority%%/*}
authority=${authority%%\?*}
authority=${authority%%\#*}

if [[ "$authority" =~ ^([^:@]+)(:([0-9]+))?$ ]]; then
  host=${BASH_REMATCH[1]}
  url_port=${BASH_REMATCH[3]:-443}
else
  echo "錯誤：無法解析網址中的主機名稱（請使用主機名稱；不支援使用者資訊或 IPv6）" >&2
  exit 2
fi

if [[ -z "$port" ]]; then
  port=$url_port
fi

tmp_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp_dir"' EXIT

split_certs() {
  local input=$1 prefix=$2
  awk -v prefix="$prefix" '
    /-----BEGIN CERTIFICATE-----/ {
      n++
      file = sprintf("%s-%02d.pem", prefix, n)
    }
    file != "" { print > file }
    /-----END CERTIFICATE-----/ {
      if (file != "") close(file)
      file = ""
    }
  ' "$input"
}

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null |
    sed 's/.*=//' | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

print_cert() {
  local cert=$1
  openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 |
    sed 's/^subject=/  Subject: /'
  openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 |
    sed 's/^issuer=/  Issuer\/CA vendor: /'
  openssl x509 -in "$cert" -noout -enddate |
    sed 's/^notAfter=/  Expires: /'
  openssl x509 -in "$cert" -noout -fingerprint -sha256 |
    sed 's/.*=/  SHA-256: /'
}

echo "檢查網址：$url"
echo "連線連接埠：$port"

openssl s_client \
  -connect "${host}:$port" \
  -servername "$host" \
  -showcerts \
  </dev/null >"$tmp_dir/server-chain.pem" 2>"$tmp_dir/openssl.log"

split_certs "$tmp_dir/server-chain.pem" "$tmp_dir/server"

leaf="$tmp_dir/server-01.pem"
if [[ ! -s "$leaf" ]]; then
  echo "❌ 無法取得伺服器憑證。"
  sed -n '1,5p' "$tmp_dir/openssl.log"
  exit 1
fi

echo
echo "伺服器憑證"
echo "  檢查的網域：$host"
print_cert "$leaf"

curl_args=(--silent --show-error --head --output /dev/null
  --connect-timeout 10 --max-time 20)

if [[ -n "$ca_file" ]]; then
  mkdir "$tmp_dir/empty-ca"
  curl_args+=(--cacert "$ca_file" --capath "$tmp_dir/empty-ca")
fi

if [[ "$port" != "$url_port" ]]; then
  curl_args+=(--connect-to "${host}:$url_port:${host}:$port")
fi

curl_args+=(--write-out 'HTTP status: %{http_code}\nTLS verify result: %{ssl_verify_result}\n')

curl_status=0
curl "${curl_args[@]}" "$url" >"$tmp_dir/curl.out" 2>"$tmp_dir/curl.err" || curl_status=$?

verify_result=$(sed -n 's/^TLS verify result: //p' "$tmp_dir/curl.out")
http_status=$(sed -n 's/^HTTP status: //p' "$tmp_dir/curl.out")

echo
if [[ "$curl_status" -eq 0 && "$verify_result" == "0" ]]; then
  if [[ -n "$ca_file" ]]; then
    echo "✅ TLS 憑證驗證成功（僅使用指定的 CA 憑證檔，未使用系統 CA 路徑）。"
  else
    echo "✅ TLS 憑證驗證成功（使用系統／預設 CA 信任庫）。"
  fi
  tls_ok=true
else
  echo "❌ TLS 憑證驗證失敗。"
  if [[ -s "$tmp_dir/curl.err" ]]; then
    echo "  curl 錯誤訊息："
    sed 's/^/    /' "$tmp_dir/curl.err"
  fi
  tls_ok=false
fi
[[ -n "$http_status" ]] && echo "HTTP 狀態碼：$http_status"

echo
echo "伺服器傳送的 CA 憑證"
server_ca_count=0
leaf_fp=$(fingerprint "$leaf")
for cert in "$tmp_dir"/server-*.pem; do
  [[ -f "$cert" ]] || continue
  cert_fp=$(fingerprint "$cert")
  [[ -n "$leaf_fp" && "$cert_fp" == "$leaf_fp" ]] && continue
  server_ca_count=$((server_ca_count + 1))
  echo "CA 憑證 ${server_ca_count}："
  print_cert "$cert"
done
if ((server_ca_count == 0)); then
  echo "伺服器未傳送 CA／中繼憑證。"
  echo "  伺服器憑證所列的簽發者："
  openssl x509 -in "$leaf" -noout -issuer -nameopt RFC2253 | sed 's/^/  /'
fi

if [[ -n "$ca_file" ]]; then
  split_certs "$ca_file" "$tmp_dir/local"

  echo
  echo "本機 CA 憑證檔：$ca_file"
  local_count=0
  for local_cert in "$tmp_dir"/local-*.pem; do
    [[ -f "$local_cert" ]] || continue
    local_count=$((local_count + 1))
    echo "本機憑證 ${local_count}："
    print_cert "$local_cert"

    local_fp=$(fingerprint "$local_cert")
    # 比對伺服器送出的每一張憑證，包含 leaf（--ca 常直接給 fullchain，第一張就是伺服器憑證）
    matched=""
    if [[ -n "$local_fp" && "$local_fp" == "$leaf_fp" ]]; then
      matched=leaf
    else
      for server_cert in "$tmp_dir"/server-*.pem; do
        [[ -f "$server_cert" ]] || continue
        if [[ -n "$local_fp" && "$local_fp" == "$(fingerprint "$server_cert")" ]]; then
          matched=chain
          break
        fi
      done
    fi

    case "$matched" in
      leaf) echo "  ✅ SHA-256 完全相符：這張就是伺服器憑證（leaf）。" ;;
      chain) echo "  ✅ SHA-256 完全相符：此憑證也出現在伺服器傳送的 CA 憑證鏈中。" ;;
      *) echo "  ❌ SHA-256 不相符：伺服器沒有傳送這張憑證。" ;;
    esac
  done

  if ((local_count == 0)); then
    echo "❌ CA 檔案中找不到 PEM 格式憑證。"
  fi
  echo "  注意：SHA-256 不相符僅表示伺服器沒有傳送該憑證（通常是根憑證）；是否成功驗證連線，請以上方 TLS 憑證驗證結果為準。"
fi