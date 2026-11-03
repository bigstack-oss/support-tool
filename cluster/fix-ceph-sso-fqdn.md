# 使用對外 FQDN 修復 Ceph Dashboard SSO

本文件為 [fix-ceph-sso-fqdn.sh](fix-ceph-sso-fqdn.sh) 的操作指南，依據 2026-10-28 提供的 bs-ai 叢集修復輸出整理。

## 本次修復結果

Ceph 端已修復成功：SAML 設定與啟用指令的結束碼皆為 0，metadata 端點回傳 HTTP 200，登入端點回傳 HTTP 303 並導向 Keycloak。後續檢查確認已儲存 `idp` 區段，且 SP URL 已改用 FQDN。本次不需要切換 manager。

提供的輸出中，**尚未驗證**瀏覽器能否完成登入，以及 Keycloak 用戶端設定是否正確。此腳本不會修改 Keycloak。

## 問題現象與診斷

```json
{"status":"400 Bad Request","detail":"Single Sign-On is not configured.","request_id":"3c87fbd6-9eb1-4189-8607-5ee4083946dc"}
```

修復前，`ceph dashboard sso status` 顯示 SAML2 已啟用，但已儲存的設定缺少 `idp` 區段。SP URL 使用 `10.120.10.210`，Keycloak 中繼資料描述檔則使用 `bs-ai.tmanh.org.tw`。

KB 記載：若設定時傳入的 IdP entity ID 與描述檔內的 `entityID` 不一致，可能在未報錯的情況下儲存缺少 `idp` 區段的設定。這與本次觀察到的狀態一致，但未取得最初執行設定的指令紀錄。僅顯示「已啟用」並不能證明 SAML 設定有效。

## 叢集設定值

| 項目 | 設定值 |
|---|---|
| 修復時的 active manager | `bs-ai-01` |
| 修復時的 standby manager 數量 | 2 |
| 修復時的叢集健康狀態 | `HEALTH_OK` |
| 對外 FQDN | `bs-ai.tmanh.org.tw` |
| 原 SP 主機位址／VIP | `10.120.10.210` |
| Dashboard 路徑前綴 | `ceph` |
| SP 基底 URL | `https://bs-ai.tmanh.org.tw:7443` |
| SP entity ID／Keycloak Client ID | `https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2/metadata` |
| ACS／允許的重新導向 URI | `https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2` |
| IdP entity ID | `https://bs-ai.tmanh.org.tw:10443/auth/realms/master` |
| IdP 中繼資料檔案 | `/etc/keycloak/saml-metadata.xml` |
| SP 憑證 | `/var/www/certs/server.cert` |
| SP 私鑰 | `/var/www/certs/server.key` |
| 使用者名稱屬性 | `username` |

## 操作步驟

請在目前的 active manager 主機上，以 root 身分執行。先將腳本複製到該主機，再執行下列指令。變更線上驗證設定前，請依維運流程取得授權。

### 1. 確認 active manager 與前置條件

```bash
ceph -s
ceph mgr stat
bash fix-ceph-sso-fqdn.sh --fqdn bs-ai.tmanh.org.tw --check
```

檢查模式不會變更 Ceph 或 Keycloak 設定。若憑證檔包含憑證鏈，腳本會建立暫存的終端憑證（leaf certificate），並在結束時刪除。

本次檢查確認：

- `bs-ai-01` 為 active manager，另有兩個 standby，叢集狀態為 `HEALTH_OK`。
- 憑證與私鑰相符，且 `*.tmanh.org.tw` 涵蓋使用的 FQDN。
- 憑證有效期間為 2026-02-24 至 2027-03-23（UTC）。
- 憑證檔包含兩張憑證；腳本擷取第一張終端憑證供 SAML 設定使用。
- IdP 描述檔要求對驗證請求簽章。
- 私鑰權限為 `644`，因此出現所有本機使用者皆可讀取的警告。調整權限前，需先確認相關服務所需的擁有者與存取權限；腳本不會修改這些權限。

### 2. 套用 Ceph 設定

僅在需要修復或變更設定時執行。本次紀錄中的修復已完成；後續檢查顯示的通用提示「Re-run with --apply」不代表必須再次套用。

```bash
bash fix-ceph-sso-fqdn.sh --fqdn bs-ai.tmanh.org.tw --apply
```

腳本會建立權限為 600 的備份，直接從描述檔讀取 IdP entity ID，將 SP URL 設為 FQDN，確認 IdP 設定已儲存後啟用 SAML2，最後檢查 metadata 與登入端點。

本次產生的備份：

```text
/root/ceph-sso-backup-20261028-111000.json
```

此備份包含舊私鑰，請勿直接貼出或作為附件分享。`ceph dashboard sso show saml2` 與 `sso setup saml2` 的原始輸出也可能包含私鑰。

### 3. 確認 Keycloak 的 Ceph 用戶端設定

在 `master` realm 中，檢查既有的 Ceph SAML 用戶端，必要時調整為：

- Client ID：`https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2/metadata`
- Valid redirect URI：`https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2`
- 簽章與加密憑證：與 SP 相符的終端憑證。
- 使用者名稱 mapper：輸出名為 `username` 的 SAML 屬性。

只將公開憑證匯入 Keycloak，切勿匯入 SP 私鑰。腳本不會執行上述用戶端設定變更。

### 4. 驗證端點與瀏覽器登入

```bash
bash fix-ceph-sso-fqdn.sh --fqdn bs-ai.tmanh.org.tw --check

curl -sS -o /dev/null -w '%{http_code}\n' \
  https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2/metadata

curl -sS -o /dev/null -w '%{http_code}\n' \
  https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2/login
```

預期 metadata 回傳 HTTP 200，登入端點重新導向 Keycloak 的 master realm（本次為 HTTP 303）。上述指令會驗證 TLS 憑證信任；若用戶端需要自訂 CA，可加上 `--cacert /path/to/ca-bundle.pem`。腳本本身使用 `curl -k`，因此腳本探測成功不代表 TLS 信任驗證已通過。

確認 Ceph 中存在與 Keycloak `username` 屬性值一致的使用者：

```bash
ceph dashboard ac-user-show <username>
```

在瀏覽器開啟下列網址，確認登入後能以預期使用者及權限進入 Dashboard：

```text
https://bs-ai.tmanh.org.tw:7443/ceph/auth/saml2/login
```

## 驗證失敗時的排查方向

| 現象 | 後續檢查 |
|---|---|
| 設定後仍缺少 `idp` 區段 | 比對描述檔中的完整 `entityID` 與已儲存的 IdP 設定，不要依 VIP 推測。 |
| Keycloak 顯示 `Invalid request` | 比對 Keycloak Client ID 與完整 SP metadata URL，包含 FQDN、連接埠及路徑前綴。 |
| 簽章或加密失敗 | 檢查終端憑證、對應私鑰，以及匯入 Keycloak 的憑證是否一致。 |
| 已儲存有效設定，但端點仍回傳 HTTP 400 | 檢查 manager 是否仍使用舊的記憶體狀態。僅在確認目前 standby 健康且取得維運授權後，才考慮切換 manager。 |
| 探測無法連線 | 從 manager 與瀏覽器用戶端確認 FQDN 解析及網路可達性。 |
| 能重新導向，但登入失敗 | 檢查 Keycloak 用戶端設定、`username` mapper，以及對應的 Ceph 使用者。 |

腳本的選用參數 `--failover-mgr` 會在端點探測失敗，且初始健康狀態與 standby 檢查符合條件時，切換 active manager。腳本不會在切換後重新探測端點，需在新的 active manager 上手動重做驗證。本次事件未使用此功能。

## 還原與設定持續性

瀏覽器登入驗證完成前，請保留受保護的備份。腳本沒有匯入 JSON 備份的指令；其建議的還原方式是使用原本的 URL、憑證及私鑰重新建立設定，並非完整還原備份 JSON。本次的舊設定原本已故障，因此恢復舊設定也無法恢復正常 SSO。

KB 提醒，平台工具可能重新產生使用 IP 的設定。執行相關平台設定提交或重新開機後，應再次確認已儲存的 URL、`idp` 區段與瀏覽器登入結果。本次提供的操作紀錄未驗證是否會再次發生。
