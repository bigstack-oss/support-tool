# SSL 憑證檢查與轉換

需求：Bash 3.2+、OpenSSL（建議 3.x 以上）、awk、grep 等基本 Unix 工具。不需 Python。無網路呼叫、不部署或修改服務。

```bash
TOOL=/Users/Roy/agent-smith/support-tool/ssl/ssl-tool.sh
```

## 支援範圍

- X.509 certificate/fullchain：PEM、DER（.crt/.cer/.pem 等，依內容判斷）。
- CSR：PEM、DER。CSR 使用 req 解析，沒有簽發者與有效期限。
- 私鑰：PEM、DER；OpenSSL 支援的 RSA、EC 等，包含加密私鑰。
- PKCS#12：.pfx/.p12；PKCS#7：PEM 或 DER (.p7b/.p7c)。
- JKS、SSH key、任意廠商容器不在支援範圍。PFX 內容無法靠副檔名完全辨識，請使用 .pfx 或 .p12。

## 資訊與一致性

```bash
"$TOOL" inspect server.crt
"$TOOL" inspect fullchain.pem --text
"$TOOL" inspect request.csr
"$TOOL" inspect server.key
"$TOOL" inspect iis_cert.pfx
"$TOOL" inspect chain.p7b
"$TOOL" match server.crt request.csr server.key
```

inspect 逐張顯示 subject、issuer、serial、有效期、SHA256 fingerprint、SAN、CA/basic constraints 和用途。--text 顯示完整公開憑證資料；私鑰只顯示公鑰，不輸出私密參數。

match 將公鑰正規化為 DER SubjectPublicKeyInfo，再比較 SHA-256，適用 RSA/EC，不依賴 RSA modulus 或 MD5。exit 0=一致，1=不一致/錯誤。fullchain/PFX 比較第一張憑證，請確保 leaf 在第一張；不代表驗證 PFX 內私鑰，若需驗證請匯出後再 match。

## 憑證鏈、用途與網域驗證

```bash
"$TOOL" verify server.crt --chain chain.crt --ca trusted-root.crt --hostname example.com
"$TOOL" verify fullchain.pem --hostname cc140.bigstack.co
```

沒有 --ca 時使用本機 OpenSSL 預設 trust store；--chain 是不受信任的中繼鏈，不會自動成為信任錨。檢查 TLS server 用途、有效期、簽章鏈與指定 DNS hostname。不下載 AIA、不查 OCSP/CRL、不驗證線上服務；--ca 請指定真正信任的 CA，不能把任意輸入憑證當 CA。

## PFX → CRT／中繼鏈／KEY

```bash
# 只匯出公開憑證；輸出目錄必須尚不存在
"$TOOL" pfx-extract iis_cert.pfx --out-dir extracted

# 同時匯出加密私鑰（互動輸入 PFX 密碼與新私鑰密碼）
"$TOOL" pfx-extract iis_cert.pfx --out-dir extracted-with-key --include-key

# 明確要求無密碼私鑰；僅限確實需要無人值守服務載入時
"$TOOL" pfx-extract iis_cert.pfx --out-dir extracted-plain --include-key --unencrypted-key
```

輸出 leaf.crt、chain.crt、選用的 private.key；檔案權限 600、目錄 700。PFX 沒有 CA 時 chain.crt 可為空。PFX 多憑證/多金鑰容器不自動配對；請檢查內容後使用。無密碼私鑰仍屬敏感資料。

## CRT＋KEY（＋chain）→ PFX

```bash
"$TOOL" pfx-create --cert server.crt --key server.key --out certificate.pfx
"$TOOL" pfx-create --cert server.crt --key server.key --chain chain.crt --out certificate.pfx
```

先驗證 cert/key 配對，不覆寫既有輸出。這兩個輸入使用 PEM。建立 PFX 不等於信任鏈驗證，另用 verify。

## PEM ↔ DER

```bash
"$TOOL" convert server.crt --format DER --out server.cer
"$TOOL" convert server.cer --format PEM --out server.pem
"$TOOL" convert request.csr --format DER --out request.der
```

一次只轉一張憑證或一個 CSR；fullchain 會拒絕，避免默默遺失中繼憑證。格式轉換不會把 ECDSA 變成 RSA。

## 密碼與舊 PFX

預設由 OpenSSL 互動詢問，不把密碼放在 CLI 參數。非互動時可指定環境變數名稱（全域選項置於子命令之前）：

```bash
# 預先以安全方式設定 PFX_PASSWORD 與 NEW_PASSWORD
"$TOOL" --pass-env PFX_PASSWORD --out-pass-env NEW_PASSWORD pfx-extract \
  iis_cert.pfx --out-dir extracted --include-key
```

多檔 match 的 --pass-env 套用所有私鑰；不同密碼時使用互動模式。舊 PFX 遇到 unsupported cipher，可在 OpenSSL 有 legacy provider 時加入全域 --legacy；不要預設開啟。

## 驗證紀錄

2026-11-03：以臨時 RSA/EC 自簽憑證驗證 certificate/CSR/key match、錯配拒絕、資訊讀取、信任鏈與 hostname 正反測試、DER 轉換、PFX 建立/匯出往返與拒絕覆寫。另以 cc140 的實際 fullchain 完成本機 trust store/hostname 驗證。未部署任何憑證或連線叢集。
