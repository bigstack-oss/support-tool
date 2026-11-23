# rancher-operation.sh / k8s-status.sh 使用場景

依「看到什麼症狀」找對應的做法。每個場景都附上 2026-11 北醫（TMUH，CubeCOS + Rancher 2.15，離線站點）實際遇到的案例。工具說明見 [TOOLS.md](TOOLS.md)。

| 工具 | 在哪跑 | 看什麼 |
|---|---|---|
| `rancher-operation.sh` | CubeCOS controller | Rancher 端：cluster 狀態、machine、plan、建 VM 的 job、mirror 設定、image 上傳 |
| `k8s-status.sh` | 下游 VM 內（sudo） | 節點端：agent、registry、rke2、image、pod、連外 |

`rancher-operation.sh --connect` 會先把 `k8s-status.sh` 複製到 VM，所以兩支通常這樣搭配：

**CubeCOS**：Rancher 端看 cluster 狀態

```bash
bash rancher-operation.sh --watch <cluster>
```

**CubeCOS → VM**：從 CubeCOS 連進節點跑 `k8s-status.sh`，看節點實際卡在哪

```bash
bash rancher-operation.sh --connect <cluster> <machine> -- sudo bash k8s-status.sh
```

controller 端每次執行的輸出都存在 `/var/log/kubernetes/`。

## 場景索引

| # | 在哪 | 症狀 | 從哪開始 |
|---|---|---|---|
| 1 | CubeCOS | 機器一直「建立 → 失敗 → 刪除 → 再建」 | `--watch` |
| 2 | CubeCOS | UI 改了 machine pool，還是用舊設定在重建 | `--watch` → `--cleanup` |
| 3 | CubeCOS | VM 建不起來：`Instance is in ERROR state` | `--watch` → Nova |
| 4 | VM | VM 起來了但 rke2 沒裝、沒啟動 | `k8s-status.sh` |
| 5 | VM → CubeCOS | 拉不到 image：`ImagePullBackOff`、`not found` | VM `k8s-status.sh --missing` → CubeCOS `--verify` / `--download` / `--upload` → VM `--retry` |
| 6 | VM → CubeCOS | 節點直接連外網拉 image（沒走 mirror） | VM `k8s-status.sh` → CubeCOS `--repo` |
| 7 | CubeCOS | 改了 mirror，部分節點還是舊的 | `--repo check` |
| 8 | VM | 要不要離線、能不能線上安裝 | `k8s-status.sh --net` |
| 9 | CubeCOS | 要 SSH 進某台 VM | `--connect` |
| 10 | VM → CubeCOS | 為下一個站點預先準備 image | VM `--used` → `--download` / `--upload` |

「在哪」：**CubeCOS** = CubeCOS controller（`rancher-operation.sh`）；**VM** = 下游 cluster 的節點內（`sudo bash k8s-status.sh`）；**VM → CubeCOS** = 先在 VM 找出問題，再到 controller 處理。

---

## 1. (CubeCOS) 機器一直刪除又重建

**症狀（在 Rancher UI / CubeCOS 看到）**：UI 的 machine pool 顯示 `0 of 1`，機器名稱一直換（例如 `runai-gpu-55nbv-4b8gr` → `-x98sp` → …），狀態在 Provisioning / Deleting 間循環。

**做法**：

**CubeCOS**：沒給 cluster 名稱時，會列出所有 cluster 讓你選

```bash
bash rancher-operation.sh --watch <cluster>
```

`--watch` 只印變化，重點看三種 ERROR：

| `--watch` 的訊息 | 意思 | 下一步 |
|---|---|---|
| `[ERROR] provision job <machine>-machine-provision-xxx failed:` + 下面幾行 log | 建 VM 的 job 失敗（OpenStack 認證、SG、flavor、quota、網路） | 依 log 內容在 Rancher UI 修 machine pool，然後看場景 2 |
| `[ERROR] machine <m>: plan failed (failures N); output:` + failed-output | VM 起來了，但節點上執行 plan 失敗 | 場景 4（進 VM 看） |
| `[ERROR] machine <m>: <failureMessage>` | CAPI 層級失敗 | 依訊息處理 |

**案例（runai，11-23）**：

```text
[ERROR] provision job runai-gpu-55nbv-4b8gr-machine-provision-fpl4z failed:
        error creating machine: ... Unable to find security_group with name or id 'defaultmdefault-k8s'
```

security group 打錯（應為 `default,default-k8s`）。另一個案例（mytestk8s）是 OpenStack `authUrl` 前面多了空白：`parse " http://...": first path segment`。

> `--watch` 每 5 秒查一次。機器若在兩次之間就被刪掉，錯誤可能來不及抓到；看到機器一直換名字卻沒有 ERROR 時，直接看場景 3 的 Nova 查法。

## 2. (CubeCOS) UI 改了，還在用舊設定重建

**症狀（在 CubeCOS 看到）**：在 UI 修好 machine pool（例如 SG），`--watch` 還是一直出現同樣的錯誤。

**原因**：UI 修改 machine pool 會產生**新的 MachineSet**，但舊的 MachineSet 仍用舊 template；滾動更新要等新機器 Ready 才縮掉舊的，舊機器一直失敗，就一直重建。

**做法**：

**CubeCOS**：修好 UI 後繼續觀察，會提示舊的 MachineSet

```bash
bash rancher-operation.sh --watch <cluster>
```

[WARN ] MachineSet runai-gpu-55nbv still builds machines from old template runai-gpu-cc757a51

(current runai-gpu-005c5e0a); remove it: bash rancher-operation.sh --cleanup runai   # [CubeCOS]

**CubeCOS**：列出差異，問 y/N 再刪（加 `--yes` 不問）

```bash
bash rancher-operation.sh --cleanup <cluster>
```

`--cleanup` 的輸出：

```text
== MachineSet runai-gpu-55nbv (pool runai-gpu): template runai-gpu-cc757a51, current runai-gpu-005c5e0a
     secGroups: "defaultmdefault-k8s" -> "default,default-k8s"
   DELETE none of its machines ever joined the cluster (nothing to lose; it only re-creates failing machines).
```

- 只刪「**沒有任何機器加入過 cluster**」的舊 MachineSet（`DELETE`）；有機器加入過的標 `KEEP`，那是正常滾動更新，可能有 etcd 資料，留給 Rancher。
- 不要手動刪「已初始化 cluster」的所有 etcd 機器：Rancher 會要求 `Restoration from etcd snapshot is required`，只能刪掉 cluster 重建（mytestk8s 的教訓）。

## 3. (CubeCOS) VM 建不起來：Instance is in ERROR state

**症狀（在 CubeCOS 的 `--watch` 看到）**：

```text
[ERROR] provision job runai-gpu-xrq4k-s7sfv-machine-provision-bvqgn failed:
        error creating machine: error in driver during machine creation: Instance creation failed. Instance is in ERROR state
```

Rancher 只知道 VM 進了 ERROR，原因在 Nova。VM 很快會被 Rancher 刪掉，所以要用 action events（刪除後仍可查）：

**CubeCOS**：找出剛被刪掉的 VM 的 ID

```bash
openstack server list --all-projects --deleted --name <machine-prefix> -f value -c ID -c Name | head -3
```

**CubeCOS**：列出該 VM 的 action（找 `create` 那筆的 Request ID）

```bash
openstack --os-compute-api-version 2.21 server event list <ID>
```

**CubeCOS**：看是哪個 event 失敗（`result: Error`）

```bash
openstack --os-compute-api-version 2.21 server event show <ID> <create 的 Request ID> -f json
```

**CubeCOS**：用 Request ID 在三台 controller 的 scheduler log 找原因

```bash
cubectl node exec -r control -p "grep -h <Request ID> /var/log/nova/nova-scheduler.log | grep -iE 'candidates|Filter|valid host'"
```

| 失敗的 event / scheduler log | 意思 |
|---|---|
| `conductor_schedule_and_build_instances` → `select_destinations` | 排程失敗（NoValidHost） |
| `Got no allocation candidates from the Placement API` | 資源、traits 或容量不符 |
| `Filtering removed all hosts ... 'XxxFilter: (start: 1, end: 0)'` | 被該 filter 排除 |
| `compute_build_and_run_instance` | 排程成功，在 compute node 上失敗（看 nova-compute.log） |

**案例（runai 4-GPU worker，11-23）**，兩個原因接連出現：

1. 沒有 allocation candidates：多 GPU device profile 寫成一個 group 要 `PGPU=4`，但每張 GPU 是獨立 provider（total 1）。改成「4 個 group、每個 PGPU=1」。
2. `AggregateInstanceExtraSpecsFilter: (start: 1, end: 0)`：flavor 的 `group_policy=isolate` 沒有 scope，filter 要求 aggregate 也有；`openstack aggregate set --property group_policy=isolate gb300` 後解決。

細節見 `issues/tmuh.org.tw/cybrog.md`「2026-11-23 事件」。

## 4. (VM) VM 起來了，但 rke2 沒裝或沒啟動

**做法**：

**CubeCOS**：連進 VM（`k8s-status.sh` 會自動複製到 VM 家目錄）

```bash
bash rancher-operation.sh --connect <cluster> <machine>
```

**VM**：檢查一次

```bash
sudo bash k8s-status.sh
```

**VM**：每 5 秒重查，只印新訊息（Ctrl-C 結束）

```bash
sudo bash k8s-status.sh --watch
```

檢查順序：主機（hostname / DNS / 磁碟 / NTP）→ 連外 → cloud-init → rancher-system-agent → registry mirror → rke2 → image → node / pod → cattle-cluster-agent。

| `k8s-status.sh` 的訊息 | 意思 / 處理 |
|---|---|
| `rke2 installed (...) but no rke2-server/rke2-agent enabled yet (plan not applied)` + `plan:` 行 | plan 卡住；看上面的 `agent:` ERROR（常見是拉 installer image 失敗 → 場景 5、6） |
| `agent: ... error loading CA cert for probe ...` | rke2-server 還沒起來時一定會有，已自動過濾；不是原因 |
| `rke2-server not active (activating auto-restart)` + `failed to get runtime image ...` | 拉不到 rke2-runtime → 場景 5、6 |
| `hostname X not resolvable (add to /etc/hosts; sudo warns)` | `echo "127.0.1.1 $(hostname)" \| sudo tee -a /etc/hosts`；映像檔 / cloud-init 應設 `manage_etc_hosts: true` |
| `no nameserver in /etc/resolv.conf` | VM 沒 DNS；Ubuntu 24.04 映像檔常見 `/etc/resolv.conf` symlink 壞掉：`sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf` |
| `clock not NTP-synchronized` | 修 NTP，否則憑證可能失效 |
| `agent registered but Rancher .../ping unreachable` | VM 到 Rancher 的路由 / 防火牆 |

**案例**：1cc 的 VM 顯示 5 行 probe CA 錯誤，真正原因藏在後面：`lookup index.docker.io on [::1]:53: connection refused`（VM 沒 DNS、也沒 mirror）→ 場景 6。

## 5. (VM → CubeCOS) 拉不到 image

**症狀（在 VM 看到）**：`sudo bash k8s-status.sh` 出現

```text
[ERROR] image pull failed: registry.rancher.com/rancher/mirrored-cilium-cilium:v1.20.4 -- not found
[ERROR] pod kube-system/cilium-m78tn Init:ImagePullBackOff (see image pull lines)
```

`not found` 代表 mirror 有通、但 `:5080` 沒有這個 image；`i/o timeout` 代表根本沒走 mirror（場景 6）。

**做法**：共 5 步，在三個地方執行。

| 步驟 | 在哪執行 | 做什麼 |
|---|---|---|
| 1 | **VM**（出問題的節點） | 列出缺的 image |
| 2 | **站點 CubeCOS**（離線站點的 controller，例 TMUH cc1） | 取回清單，確認 registry 實際缺哪些 |
| 3 | **有網路的 CubeCOS**（例 cc141） | 下載 image |
| 4 | **站點 CubeCOS** | 上傳到每台 controller 的 `:5080`，再驗證 |
| 5 | **VM** | 讓卡住的 pod 立刻重拉 |

**步驟 1｜VM**：列出缺的 image

**VM**：結果寫到 `~/missing-images.txt`（完整 image 名稱）

```bash
sudo bash k8s-status.sh --missing
```

**步驟 2｜站點 CubeCOS**：取回清單，確認 VIP registry 實際缺哪些

**CubeCOS**：把清單從 VM 複製回來（金鑰與 FIP 見 `--connect` 的輸出）

```bash
scp -i /tmp/rancher-keys-0/<machine>-id_rsa ubuntu@<FIP>:missing-images.txt .
```

**CubeCOS**：比對 VIP registry，印出 `10/12 ok` 與缺的 image，缺的寫到 `missing-now.txt`

```bash
bash rancher-operation.sh --verify missing-images.txt missing-now.txt
```

**步驟 3｜有網路的 CubeCOS**：把 `missing-now.txt` 帶過去，下載

**CubeCOS**（有網路的）：下載到 `offline-images-fix/`

```bash
bash rancher-operation.sh --download missing-now.txt offline-images-fix
```

**步驟 4｜站點 CubeCOS**：把 `offline-images-fix/` 帶回來，上傳並驗證

**CubeCOS**：用絕對路徑進入放 `offline-images-fix/` 的目錄（避免 `getcwd` 錯誤）

```bash
cd /絕對路徑/
```

**CubeCOS**：推到每台 controller 的 `:5080`

```bash
bash rancher-operation.sh --upload offline-images-fix
```

**CubeCOS**：再比對一次，應為 `N/N ok`

```bash
bash rancher-operation.sh --verify missing-now.txt
```

**步驟 5｜VM**：讓卡住的 pod 立刻重拉

**VM**：讓卡住的 pod 立刻重拉（server 節點刪 pod，worker 節點直接 `crictl pull`）

```bash
sudo bash k8s-status.sh --retry
```

**VM**：確認 `image pull failed` 消失、pod 變成 Running

```bash
sudo bash k8s-status.sh --watch
```

- `--retry` 在 server 節點刪除 ImagePullBackOff 的 pod；在 worker（沒有 kubeconfig）改用 `crictl pull` 直接把缺的 image 拉下來，kubelet 下次重試就會啟動。
- 站點 CubeCOS 本身能連外時（`curl https://registry-1.docker.io/v2/` 有回應），步驟 3 可直接在站點 CubeCOS 執行，不必搬檔案。
- **`--missing` 只列出已經失敗的 image**：補一個、往前一步、再缺下一個，會來回很多次。新版本、新站點請先用完整清單：RKE2 release 的 `rke2-images-core` 加上**所選 CNI**（`rke2-images-cilium` 或 `-calico`）加上 chart 的 `chart-images.txt`。
- 步驟 4 上傳時出現 `getcwd: cannot access parent directories`：shell 所在目錄被刪除或重新掛載，用絕對路徑重新 `cd`。

**案例（runai，11-20）**：叢集選了 Cilium，但離線包只帶了 Calico，`--missing` 每次只抓到 2–3 個，補了三輪；最後直接下載整份 `rke2-images-cilium.linux-amd64.txt`（9 個 image）一次解決。

## 6. (VM → CubeCOS) 節點直接連外網拉 image（沒走 mirror）

**症狀（在 VM 看到）**：`sudo bash k8s-status.sh` 出現

```text
[WARN ] no registry mirror on this node (cluster spec rkeConfig.registries empty): images pull from the internet
[ERROR] rke2-server: ... failed to get runtime image registry.rancher.com/rancher/rke2-runtime:v1.36.6-rke2r1: ... dial tcp 18.198.47.126:443: i/o timeout
```

或 agent 拉 installer image 失敗：`lookup index.docker.io on [::1]:53: connection refused`。

**原因（在 CubeCOS 設定）**：cluster spec 沒有 `rkeConfig.registries`，Rancher 下發給節點的 registries.yaml 是空的，節點只能直接連外網。修正在 CubeCOS 端做，Rancher 再把新設定推到節點。

| 步驟 | 在哪執行 | 做什麼 |
|---|---|---|
| 1 | **VM** | 確認節點拿到的是空的 mirror 設定 |
| 2 | **CubeCOS** | 確認 cluster spec 沒有 mirror |
| 3 | **CubeCOS** | 加上 mirror |
| 4 | **CubeCOS** | 等 Rancher 逐台推到節點 |
| 5 | **VM** | 確認 mirror 生效、rke2 起來 |

**步驟 1｜VM**：確認節點拿到的 mirror 設定

**VM**：看節點拿到的 mirror 設定；`{"configs":{},"mirrors":null}` 代表沒有 mirror

```bash
sudo cat /etc/rancher/rke2/registries.yaml
```

**步驟 2｜CubeCOS**：確認 cluster spec

**CubeCOS**：看 cluster spec 的 registries，以及每台節點 plan 帶的 mirror

```bash
bash rancher-operation.sh --repo <cluster> check
```

```text
== spec.rkeConfig.registries of roy-test
{}
== mirrors in each node's plan (what lands in /etc/rancher/*/registries.yaml)
  roy-test-pool1-9twlq-cvpfm                    NO MIRROR
```

**步驟 3｜CubeCOS**：加上 mirror

**CubeCOS**：先選要 inject 的 registry（Enter = ALL），再選 URL（Enter = VIP:5080）

```bash
bash rancher-operation.sh --repo <cluster> update
```

```text
Registries to mirror:
  1) ALL
  2) docker.io  3) index.docker.io  4) quay.io  5) registry-1.docker.io
  6) registry.k8s.io  7) registry.rancher.com  8) nvcr.io
Select, several allowed (e.g. 2 4 6) [1]:
Mirror URL(s), space-separated [http://<cubesys.control.vip>:5080]:
```

- **`registry.rancher.com` 一定要選**：RKE2 v1.36 的 runtime 與 Rancher 2.14+ 的 CAPI image 都從這裡拉。
- **`nvcr.io`**：要離線裝 NVIDIA GPU Operator 時才需要。
- Mirror 預設指向 VIP；`--upload` 會推到每台 controller（`cubesys.control.addrs`），所以 VIP 換到哪台都有 image。
- 原值會印在畫面上（也在 `/var/log/kubernetes/` 的 run log）。

**步驟 4｜CubeCOS**：等 Rancher 逐台推到節點（見場景 7）

**CubeCOS**：確認每台節點都顯示選的 registry，沒有 `<- old plan`

```bash
bash rancher-operation.sh --repo <cluster> check
```

**步驟 5｜VM**：確認 mirror 生效

**VM**：確認出現 mirrors

```bash
sudo cat /etc/rancher/rke2/registries.yaml
```

**VM**：應看到 `registry http://<VIP>:5080 reachable`，接著 `rke2-server active`

```bash
sudo bash k8s-status.sh --watch
```

若之後出現 `image pull failed: ... not found`：mirror 已生效、只是 `:5080` 缺 image → 場景 5。

- `--repo <cluster> reset`（CubeCOS）會清掉所有 mirror 與 configs（`registries = {}`），離線站點 reset 後無法拉新 image。

**案例**：roy-test、1cc 都是在 UI 手動建的 cluster，沒有 registries；`rke2-generator.sh` 產生的 `03-edit-cluster.yaml` 會自動帶上。

## 7. (CubeCOS) 改了 mirror，部分節點還是舊的

**症狀（在 CubeCOS 看到）**：`--repo update` 或 `reset` 後，`check` 顯示有節點還是舊的設定。

```text
== mirrors in each node's plan (what lands in /etc/rancher/*/registries.yaml)
  v35-pool1-srkp5-69w27      NO MIRROR
  v35-pool1-srkp5-bgzgg      docker.io,quay.io,registry.k8s.io,registry.rancher.com   <- old plan, not rolled out yet
2 node(s) pending: Rancher rolls plans node by node (upgradeStrategy concurrency, default 1); re-check in a few minutes.
```

**原因**：`--repo` 只改 cluster spec，Rancher 依 `upgradeStrategy` concurrency（預設 1）**逐台**套用並重啟 rke2，不是腳本漏做。過幾分鐘再 `check`。

**例外**：cluster 從未起來、bootstrap 節點一直沒收到新 plan（`check` 一直顯示 `NO MIRROR`）時，在該 VM 手寫 `/etc/rancher/rke2/registries.yaml` 後 `systemctl restart rke2-server`，或刪掉 cluster 重建。

## 8. (VM) 能不能連外（線上 / 離線決策）

**VM**：只檢查連外（一般檢查也會跑這段）

```bash
sudo bash k8s-status.sh --net
```

```text
[INFO ] network: default route 192.168.1.1 (ens3), nameservers 8.8.8.8 10.170.51.110, rke2 proxy none
[OK   ] internet: registry-1.docker.io reachable (52.7.124.56, HTTP 401, 0.60s)
[WARN ] internet: nvcr.io resolves to 34.215.85.124 but HTTPS fails (firewall, no route, or proxy needed)
[WARN ] internet: quay.io DNS lookup failed
[OK   ] internet: 3/5 registries reachable
```

- HTTP 401 是 registry 對 `/v2/` 的正常回應，代表可連。
- 全部連不到只算 WARN：離線站點本來就靠 mirror。
- 要逐台檢查整個 cluster：

  **CubeCOS → VM**：在 CubeCOS 執行，逐台連進 cluster 的每個節點跑 `k8s-status.sh --net`

  ```bash
  for m in $(k3s kubectl -n fleet-default get machines.cluster.x-k8s.io -l cluster.x-k8s.io/cluster-name=<cluster> -o jsonpath='{.items[*].metadata.name}'); do echo "== $m"; bash rancher-operation.sh --connect <cluster> "$m" -- sudo bash k8s-status.sh --net; done
  ```

**案例（runai，11-23）**：3 台 control 都能連外，GPU worker 能 ping 8.8.8.8 但 DNS 失敗（GPU 映像檔缺 `/etc/resolv.conf`），修好 DNS 後 GPU Operator 改用線上安裝。

## 9. (CubeCOS) SSH 進某台 VM

**CubeCOS**：選 cluster → 選 machine → 登入

```bash
bash rancher-operation.sh --connect
```

**CubeCOS**：直接指定 cluster 與 machine

```bash
bash rancher-operation.sh --connect <cluster> <machine>
```

**CubeCOS → VM**：不登入，只在 VM 上跑一個指令

```bash
bash rancher-operation.sh --connect <cluster> <machine> -- sudo bash k8s-status.sh
```

- 自動取 SSH 金鑰（secret `<machine>-machine-state`，等同 UI 的 Download SSH Key）、找 FIP（`openstack server list --all-projects`）、取 `sshUser`。
- 每次連線前把 `k8s-status.sh` 複製到 VM 家目錄。
- 金鑰在 `/tmp/rancher-keys-<uid>/`（目錄 700），用完可 `rm -rf /tmp/rancher-keys-$(id -u)`。

## 10. (VM → CubeCOS) 為下一個站點預先準備 image

在一個**已經跑起來**的 cluster 上：

**VM**（server 節點）：本機 image 加上全 cluster pod 用到的 image，寫到 `used-images.txt`

```bash
sudo bash k8s-status.sh --used
```

**CubeCOS**（有網路的）：下載

```bash
bash rancher-operation.sh --download used-images.txt offline-images-next
```

帶到新站點 controller

**CubeCOS**（新站點）：上傳到每台 controller 的 `:5080`

```bash
bash rancher-operation.sh --upload offline-images-next
```

**CubeCOS**（新站點）：確認都在 registry

```bash
bash rancher-operation.sh --verify used-images.txt
```

再加上新站點會用到但這個 cluster 沒用到的元件（例如不同 CNI、GPU Operator 的 `gpu-operator-images.txt`）。

---

## 附：常用一行

| 要做什麼 | 在哪 | 指令 |
|---|---|---|
| 跟 cluster 建立進度 | CubeCOS | `bash rancher-operation.sh --watch <cluster>` |
| 清掉用舊 template 的 MachineSet | CubeCOS | `bash rancher-operation.sh --cleanup <cluster>` |
| 看 / 改 mirror | CubeCOS | `bash rancher-operation.sh --repo <cluster> check \| update \| reset` |
| image 在不在 registry | CubeCOS | `bash rancher-operation.sh --verify <list>` |
| 下載 / 上傳 image | CubeCOS（下載：有網路的；上傳：站點） | `--download <list> [DIR]`（有網路主機）/ `--upload [DIR]`（離線 controller） |
| 進 VM | CubeCOS | `bash rancher-operation.sh --connect <cluster> <machine>` |
| 節點狀態 | VM | `sudo bash k8s-status.sh [--watch]` |
| 缺的 image / 用到的 image | VM | `sudo bash k8s-status.sh --missing` / `--used` |
| 讓 pod 立刻重拉 | VM | `sudo bash k8s-status.sh --retry` |
| 連外檢查 | VM | `sudo bash k8s-status.sh --net` |
