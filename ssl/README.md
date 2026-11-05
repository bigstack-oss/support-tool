# SSL 憑證檢查與轉換（Bash）

需求：Bash 3.2+、OpenSSL 3.x+、awk、grep、find 等 Unix 工具；執行不需要 Python。

```bash
TOOL=/Users/Roy/agent-smith/support-tool/ssl/ssl-tool.sh
"$TOOL" --help
"$TOOL" --url https://example.com
"$TOOL" -i fullchain.pem
"$TOOL" -i server.crt -t
"$TOOL" -i request.csr
"$TOOL" -i private.key
"$TOOL" -i certificate.pfx
"$TOOL" -i chain.p7b
"$TOOL" -m server.crt request.csr private.key
"$TOOL" verify fullchain.pem
"$TOOL" verify server.crt
"$TOOL" -v -d ./certificates
```

支援 PEM/DER X.509、CSR、私鑰、PKCS#7、PFX/P12（後者需 .pfx/.p12 副檔名）。不包含 JKS/SSH key。
`--url URL` 會執行 `curl -ivk`，但只輸出 curl 的 `Server certificate:` 區塊；`-k` 會略過伺服器憑證信任驗證，因此這是檢視遠端憑證資訊，不是信任性驗證。
inspect 逐張顯示 leaf/中繼憑證資訊；私鑰僅顯示公鑰。CSR 沒有有效期或簽發者。
match 使用 DER 公鑰 SHA-256，支援 RSA/EC；不使用 MD5/modulus。fullchain/PFX 比較第一張憑證，請確認 leaf 排第一。PFX 內私鑰若要驗證，先匯出再 match。
verify 可指定單一憑證檔或目錄；目錄會遞迴掃描。`-v -d DIR` 是 `verify -d DIR` 的簡寫。每張憑證會列出 Subject、Issuer/CA provider、序號、有效起訖時間和所有 SAN 項目（包括 DNS 網域及 IP），每個檔案只顯示一個彙總驗證結果（例如 `3/3 certificates`）。它會用 OpenSSL 系統信任庫檢查簽章鏈，leaf 憑證會以 TLS server 用途驗證；CA 憑證作為鏈憑證驗證。遇到 PFX/P12 時只詢問一次解密密碼，並重用於本次掃描；非互動可用全域 `--pass-env NAME`。目錄中的 PEM、DER、PKCS#7、PFX/P12 檔案會檢查，其他檔案列為略過；若任一憑證失敗，命令會以非零狀態結束。請將 leaf 與所需中繼憑證放在同一 fullchain，或一起放在掃描目錄中。此簡化模式不接受自訂 CA 或 hostname；不查 OCSP/CRL、不下載 AIA、不檢查線上服務。

## PFX 匯出與建立

```bash
# 匯出 server.crt、chain.crt 和合併的 fullchain.crt；目錄可已存在或由工具建立
"$TOOL" -x iis.pfx -d extracted
# 同時匯出無密碼 private.key
"$TOOL" -x iis.pfx -d extracted-key
# 從目錄建立 PFX：自動尋找唯一配對的 leaf 與私鑰，其餘憑證作 chain
"$TOOL" -c -d extracted-key -o result.pfx
```

輸出檔案權限 600；新建目錄權限 700。`server.crt` 是 PFX leaf，`chain.crt` 是 CA 鏈（沒有 CA 時可為空），`fullchain.crt` 是 server 憑證後接 CA 鏈，`private.key` 一律以無密碼 PEM 格式匯出。因私鑰未加密，請妥善保護檔案與目錄，並在不再需要時安全移除。可匯出至既有目錄，若 `server.crt`、`chain.crt`、`fullchain.crt` 或 `private.key` 已存在會以新內容取代；同名目錄不會被覆寫。舊版輸出的 `leaf.crt` 會在成功匯出後移除。
`-x` 是 `pfx-extract` 的簡寫，`-c` 是 `pfx-create` 的簡寫；完整命令名稱仍可使用。`pfx-create` 的 `-d DIR` 會遞迴掃描 PEM/DER 憑證與私鑰：必須找到唯一一把有效私鑰，以及唯一一張與其配對的憑證；其他不重複憑證會作為 chain。若目錄同時有 `server.crt` 和包含它的 `fullchain.crt`，重複憑證只會納入一次。可直接使用 `pfx-extract` 建立的目錄建立 PFX。未知/不相關檔案會略過，錯誤的憑證或 `.key` 檔會拒絕處理。
短選項 `-i`、`-m` 分別是 `inspect`、`match` 的簡寫。`-d`、`-o`、`-t` 分別對應 `--out-dir`、`--out`、`--text`；轉換時 `-f` 對應 `--format`。建立 PFX 時 chain 由目錄掃描自動組合，不需要 `-f`。完整命令名稱和舊長選項仍可使用。
`pfx-extract` 只詢問一次「Decrypt password」並重用於各匯出步驟。非互動時可用全域 `--pass-env NAME` 指定環境變數名稱：

```bash
"$TOOL" --pass-env PFX_PASSWORD -x iis.pfx -d extracted-key
```

需事先安全設定上述環境變數；不要把密碼寫入腳本。舊 PFX 若遇 unsupported cipher，可使用全域 --legacy（需 legacy provider）。

## PEM / DER 轉換

```bash
"$TOOL" convert server.crt -f DER -o server.cer
"$TOOL" convert server.cer -f PEM -o server.pem
"$TOOL" convert request.csr -f DER -o request.der
```

一次只轉單張憑證/CSR，拒絕 fullchain 以避免遺失中繼鏈。格式轉換不會改變 RSA/ECDSA 金鑰演算法。

## 恢復紀錄

2026-11-03：目錄遺失後，依對話中的 Bash 版本重建 ssl-tool.sh 與本說明。未連線或變更叢集。使用臨時 RSA/EC fixtures 驗證配對、錯配拒絕、inspect、hostname 驗證、DER、PFX 往返與拒絕覆寫。
