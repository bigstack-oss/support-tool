# SSL 憑證檢查與轉換（Bash）

需求：Bash 3.2+、OpenSSL 3.x+、awk、grep、find 等 Unix 工具；執行不需要 Python。

```bash
TOOL=/Users/Roy/agent-smith/support-tool/ssl/ssl-tool.sh
"$TOOL" --help
"$TOOL" inspect fullchain.pem
"$TOOL" inspect server.crt -t
"$TOOL" inspect request.csr
"$TOOL" inspect private.key
"$TOOL" inspect certificate.pfx
"$TOOL" inspect chain.p7b
"$TOOL" match server.crt request.csr private.key
"$TOOL" verify fullchain.pem
"$TOOL" verify server.crt
"$TOOL" -v -d ./certificates
```

支援 PEM/DER X.509、CSR、私鑰、PKCS#7、PFX/P12（後者需 .pfx/.p12 副檔名）。不包含 JKS/SSH key。
inspect 逐張顯示 leaf/中繼憑證資訊；私鑰僅顯示公鑰。CSR 沒有有效期或簽發者。
match 使用 DER 公鑰 SHA-256，支援 RSA/EC；不使用 MD5/modulus。fullchain/PFX 比較第一張憑證，請確認 leaf 排第一。PFX 內私鑰若要驗證，先匯出再 match。
verify 可指定單一憑證檔或目錄；目錄會遞迴掃描。`-v -d DIR` 是 `verify -d DIR` 的簡寫。每張憑證會列出 Subject、Issuer/CA provider、序號、有效起訖時間和所有 SAN 項目（包括 DNS 網域及 IP），每個檔案只顯示一個彙總驗證結果（例如 `3/3 certificates`）。它會用 OpenSSL 系統信任庫檢查簽章鏈，leaf 憑證會以 TLS server 用途驗證；CA 憑證作為鏈憑證驗證。遇到 PFX/P12 時只詢問一次解密密碼，並重用於本次掃描；非互動可用全域 `--pass-env NAME`。目錄中的 PEM、DER、PKCS#7、PFX/P12 檔案會檢查，其他檔案列為略過；若任一憑證失敗，命令會以非零狀態結束。請將 leaf 與所需中繼憑證放在同一 fullchain，或一起放在掃描目錄中。此簡化模式不接受自訂 CA 或 hostname；不查 OCSP/CRL、不下載 AIA、不檢查線上服務。

## PFX 匯出與建立

```bash
# 只匯出 leaf.crt / chain.crt；目錄可已存在或由工具建立
"$TOOL" pfx-extract iis.pfx -d extracted
# 加密私鑰 private.key
"$TOOL" pfx-extract iis.pfx -d extracted-key -k
# 明確要求無密碼私鑰
"$TOOL" pfx-extract iis.pfx -d extracted-plain -k -u
# PEM 憑證與私鑰建立 PFX，chain 可省略
"$TOOL" pfx-create --cert server.crt --key server.key --chain chain.crt -o result.pfx
```

輸出檔案權限 600；新建目錄權限 700。可匯出至既有目錄，若 `leaf.crt`、`chain.crt` 或要匯出的 `private.key` 已存在會以新內容取代；同名目錄不會被覆寫。PFX 沒有 CA 時 chain.crt 可為空；多金鑰容器不自動判斷配對。
短選項 `-d`、`-k`、`-u`、`-o`、`-t`、`-f` 分別對應 `--out-dir`、`--include-key`、`--unencrypted-key`、`--out`、`--text`、`--format`；舊長選項仍可使用。
`pfx-extract` 只詢問一次「Decrypt password」並重用於各匯出步驟。若匯出加密私鑰，還會另外詢問輸出私鑰的密碼；可透過 `--out-pass-env` 指定。非互動時可用環境變數名稱，全域選項放子命令前：

```bash
"$TOOL" --pass-env PFX_PASSWORD --out-pass-env NEW_PASSWORD pfx-extract iis.pfx -d extracted-key -k
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
