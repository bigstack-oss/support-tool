# SSL 憑證檢查與轉換（Bash）

需求：Bash 3.2+、OpenSSL 3.x+、awk、grep、find 等 Unix 工具；執行不需要 Python。

## 工具一覽

| 檔案 | 在哪裡跑 | 用途 |
| --- | --- | --- |
| `certbot-generator.sh` | Mac / 工作機 | 為 `SUBDOMAIN.bigstack.co` 申請 Let's Encrypt **RSA 2048** 憑證（Cloudflare DNS 驗證），建立 A 記錄並排程 90 天後自動刪除；輸出 `FQDN.pem` + `FQDN.key` 到目前目錄 |
| `ssl-tool.sh` | 任何地方 | 檢視、驗證、轉換憑證／私鑰／PFX（見下方詳細說明） |
| `set-domain.sh` | CubeCOS control node（root） | 把叢集對外名稱從 VIP 改成 FQDN：所有對外 port 的 TLS 憑證、SAML SSO、Keycloak clients；也用於憑證續約 |
| `fix-ceph-sso-fqdn.sh` | 由 `set-domain.sh` 呼叫 | Ceph Dashboard SAML SSO 設定；必須和 `set-domain.sh` 放在**同一個目錄** |
| `ssl-checker.sh` | 任何地方 | 從外部檢查某個 port 實際送出的憑證鏈與信任結果 |

## CubeCOS 更換 FQDN／SSL 憑證流程

前提：DNS 已把 FQDN 指向叢集 VIP（每台 control node 都要能解析）；憑證必須是 **RSA**（SAML 簽章需要，ECDSA 不行）；叢集為 HA（有 VIP）。已在 CubeCOS 3.1.0 與 3.2.0 上使用過。

### 1. 取得憑證

```bash
# bigstack.co 測試環境：自動申請（RSA）
bash certbot-generator.sh cc140 10.32.10.140        # -> cc140.bigstack.co.pem / .key
# 客戶憑證：直接把 CA 給的檔案放進一個目錄即可，例如 TWCA 的
#   chain.crt  fullchain.crt  private.key  server.crt
```

`set-domain.sh -c DIR` 會自己從目錄找出 leaf、配對的私鑰與中繼憑證，去除重複、排好順序，產生 `server.cert`（leaf + 中繼）、`server.key`、`server.pem`（cert + key）。檔名與格式不拘（fullchain + privkey、單一合併檔、PFX 匯出的 4 個檔…）；同目錄其他網域的檔案會被忽略。私鑰不能加密。

### 2. 先在本機檢查憑證

```bash
bash ssl-tool.sh -v -d ./cert        # 鏈是否完整、私鑰是否配對、到期日
```

### 3. 複製到任一台 control node

```bash
scp set-domain.sh fix-ceph-sso-fqdn.sh root@VIP:/root/
scp -r ./cert root@VIP:/root/cert
```

### 4. check（預設，唯讀）→ apply → verify

```bash
bash /root/set-domain.sh cc140.bigstack.co -c /root/cert             # check：不改任何東西，列出計畫
bash /root/set-domain.sh cc140.bigstack.co -c /root/cert --apply     # 再跑一次 check，顯示計畫，輸入 YES 才執行
bash /root/set-domain.sh cc140.bigstack.co -c /root/cert --verify    # 之後隨時可做的唯讀檢查
```

- 輸出符號：✅ 正常、⚠️ 警告（不擋）、❌ 問題（apply 會停下、不做任何變更）。
- check 每台節點會印一行 `now:`：目前 `server.cert` 幾張、5443／9999 讀哪個檔，可看出原本的問題。
- apply 會依序做：備份 → Keycloak FQDN clients → keystone remote_id → k3s 10443 ingress（SNI）→ 每台 control node（憑證、SSO、Skyline、Horizon、noVNC、Grafana，逐台重啟）→ compute node 的 noVNC 網址 → Ceph 憑證與 SSO → Rancher → 最後做 domain check。
- 一般會中斷 SSO 登入、各服務逐台重啟、Rancher 重啟；建議離峰執行，並用 tmux／screen（約 10–15 分鐘）。
- `--fqdn-only`：用於 Keycloak clients **已被手動改成 FQDN** 的叢集（IP clients 不存在），保留現有 clients、只更新憑證，完全不碰 IP clients。
- 不改：Rancher server-url、OpenStack endpoint、haproxy-ha、內部 URL；用 IP 存取仍走原本的自簽憑證。

### 5. 從外部確認

```bash
for p in 443 5443 6080 7443 8005 9999 10443; do bash ssl-checker.sh --ca cert/fullchain.crt https://cc140.bigstack.co $p; done
```

再用瀏覽器無痕視窗測試：CubeCOS UI、Skyline（:9999）、Ceph（:7443/ceph/）、Rancher（:10443）登入，以及 VM console（:6080）。

### 6. 憑證續約

新憑證放進新目錄，重跑同一個 `--apply`（可重複執行，已設定的部分不會改變，只換憑證與 Keycloak 的 SP 憑證），完成後 `--verify`。不要只手動覆蓋 `/var/www/certs`：Keycloak、Ceph、k3s secret、nova 的副本都要一起換，否則 SSO 會壞。

### 7. Rollback

每次 apply 都會備份到 `/root/set-domain-backup/DOMAIN-TIME/`（含私鑰，權限 700），中斷或失敗時會印出還原指令：

```bash
bash /root/set-domain.sh --rollback /root/set-domain-backup/cc140.bigstack.co-20261106-103644
```

只還原實際執行過的步驟（順序相反）。

## ssl-tool.sh

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
"$TOOL" verify fullchain.pem
"$TOOL" verify server.crt
"$TOOL" -v -d ./certificates
```

`ssl-checker.sh` 會檢查 HTTPS 網址，並以繁體中文顯示伺服器憑證、伺服器傳送的 CA 憑證、到期日、SHA-256 指紋及 TLS 驗證結果：

```bash
bash ./ssl-checker.sh https://example.com
bash ./ssl-checker.sh --ca chain.crt https://example.com
bash ./ssl-checker.sh --ca chain.crt https://example.com 8443
```

指定 `--ca` 時，驗證只使用該 CA 憑證檔，並停用系統 CA 路徑。本機 CA 指紋比對是與伺服器實際傳送的憑證逐一比對；沒有比對到不代表 TLS 驗證失敗，因為伺服器通常不會傳送根憑證（若用戶端已有中繼憑證，伺服器也可能省略）。

支援 PEM/DER X.509、CSR、私鑰、PKCS#7、PFX/P12（後者需 .pfx/.p12 副檔名）。不包含 JKS/SSH key。
`--url URL` 會執行 `curl -ivk`，但只輸出 curl 的 `Server certificate:` 區塊；`-k` 會略過伺服器憑證信任驗證，因此這是檢視遠端憑證資訊，不是信任性驗證。
inspect 逐張顯示 leaf/中繼憑證資訊；私鑰僅顯示公鑰。CSR 沒有有效期或簽發者。
verify 可指定單一憑證檔或目錄；目錄會遞迴掃描。`-v -d DIR` 會列出每張憑證的 Subject、Issuer/CA provider、序號、有效起訖時間、SAN 和 MD5 指紋，並在輸出末尾以 `SHA256 公鑰雜湊  檔名` 列出每個憑證/私鑰檔案的公鑰雜湊；fullchain 使用第一張憑證的公鑰。此公鑰 SHA-256 也用於比對目錄中的私鑰與憑證。MD5 僅供憑證識別，不用於配對或安全驗證。每個憑證檔案只顯示一個彙總信任驗證結果（例如 `3/3 certificates`）。工具會用 OpenSSL 系統信任庫檢查簽章鏈，leaf 憑證會以 TLS server 用途驗證；CA 憑證作為鏈憑證驗證。遇到 PFX/P12 時只詢問一次解密密碼，並重用於本次掃描；非互動可用全域 `--pass-env NAME`。目錄中的 PEM、DER、PKCS#7、PFX/P12 檔案會檢查，其他檔案列為略過；若任一憑證或私鑰配對失敗，命令會以非零狀態結束。請將 leaf 與所需中繼憑證放在同一 fullchain，或一起放在掃描目錄中。此簡化模式不接受自訂 CA 或 hostname；不查 OCSP/CRL、不下載 AIA、不檢查線上服務。

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
短選項 `-i` 是 `inspect` 的簡寫。`-d`、`-o`、`-t` 分別對應 `--out-dir`、`--out`、`--text`；轉換時 `-f` 對應 `--format`。建立 PFX 時 chain 由目錄掃描自動組合，不需要 `-f`。完整命令名稱和舊長選項仍可使用。
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
