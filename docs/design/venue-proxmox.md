# 会場 Proxmox サーバー設計書

## 概要

会場側のネットワーク機能 (r3 VyOS, ローカルサーバー) を単一の物理サーバー上の Proxmox VE で仮想化し、運搬する機材数を最小化する。

### 仮想化の動機

- **運搬コスト削減**: 会場に持ち込む物理サーバーを 1 台に集約
- **経路切替の柔軟性**: WireGuard 直接接続 / wstunnel 経由を VyOS 上で切り替え可能。物理配線の変更不要

### プロキシ回避方式

会場上流がプロキシ環境の場合、wstunnel (WebSocket トンネル) を VyOS 上の podman コンテナとして動作させる。wstunnel は WireGuard の UDP パケットを WebSocket (TLS over TCP 443) にカプセル化し、HTTP CONNECT プロキシを透過する。SoftEther のような専用 CT や内部ブリッジが不要で、VyOS の設定体系に統合できる。

技術調査の詳細は [`../investigation/tailscale-derp-tcp443-fallback-investigation.md`](../investigation/tailscale-derp-tcp443-fallback-investigation.md) を参照。

## ハードウェア

### 本体

**Dell OptiPlex 3070 Micro**

| 項目 | 仕様 |
|------|------|
| CPU | Intel Core i5-9500T (6C/6T) |
| RAM | DDR4 32GB |
| ストレージ | M.2 NVMe SSD 512GB + HDD 1TB |

RAM 割り当て:
.
| 用途 | RAM | 備考 |
|------|-----|------|
| VyOS VM (r3) | 6GB | BGP + DNS/DHCP + Flow Accounting + wstunnel (podman) の並行処理 |
| ローカルサーバー CT | 16GB | Grafana, rsyslog, nfcapd, SNMP Exporter (200名規模対応) |
| Proxmox ホスト | 3GB | Web UI, カーネル, ZFS ARC |
| **予備** | **7GB** | 追加 CT (キャプティブポータル, DNS キャッシュ等) や突発対応 |
| **合計** | **32GB** | |

※ wstunnel は VyOS の podman コンテナとして動作するため、SoftEther CT (旧設計: 1GB) は不要。予備 RAM が 1GB 増加。

ストレージ用途:
- **NVMe SSD 512GB**: Proxmox OS、VM/CT のルートディスク
- **HDD 1TB**: ログ保存 (rsyslog, nfcapd)、Grafana データなど長期保存用

### NIC 構成

| NIC | チップ | ドライバ | 速度 | IF 名 | 接続 | 役割 |
|-----|--------|---------|------|-------|------|------|
| オンボード | Realtek RTL8168H | r8169 | 1GbE | nic0 | PCIe (`0000:01:00.0`) | **トランク** (→ PoE スイッチ) |
| 外付け | Realtek RTL8156B | r8152 | 2.5GbE | nic1 | USB 3.0 (`usb-0000:00:14.0-4`) | **アップリンク** (→ blackbox) |

#### NIC 役割の割り当て理由

- **オンボード → トランク**: 物理的に安定。VLAN 11/30/40 の全トラフィックを担う。オンボード NIC の脱落リスクはゼロ
- **USB NIC → アップリンク**: 会場の上流回線は 1GbE 未満が想定され、2.5GbE の帯域は不要。万一 USB NIC が抜けても会場内 LAN (DHCP/DNS/VLAN 間通信) は維持される

#### USB NIC の物理固定

USB NIC はテープで固縛し、物理的な抜け落ちを防止する。

#### ドライバに関する注意

**Realtek RTL8111H (オンボード)**:

Proxmox (Debian カーネル) では `r8169` ドライバで認識されることが多い。不安定な場合は `r8168` DKMS パッケージを導入する。

```bash
# ドライバ確認
ethtool -i <interface> | grep driver

# r8169 で不安定な場合
apt install pve-headers-$(uname -r)
apt install r8168-dkms
```

**USB 2.5GbE NIC**:

`udev` ルールでインターフェース名を固定し、再起動時の名前変動を防ぐ。

```bash
# /etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="00:e0:4c:92:ee:41", NAME="enxusb0"
```

実機確認済み: RTL8156B (r8152 ドライバ, FW: rtl8156b-2 v3)。Proxmox 6.17 カーネルで認識済み。

## Proxmox 仮想ネットワーク設計

### ブリッジ構成

| ブリッジ | bridge-ports | 接続先 | 用途 |
|---------|-------------|--------|------|
| vmbr0 | nic1 | USB NIC (アップリンク) | 会場上流 (blackbox) への接続。DHCP でアドレス取得 |
| vmbr_trunk | nic0 | オンボード NIC (Realtek) | VyOS → PoE スイッチ (VLAN トランク)。Proxmox 管理 IP (192.168.11.3/24) |

※ 旧設計の vmbr1 (SoftEther ↔ VyOS 間の内部ブリッジ) は wstunnel 移行により廃止。wstunnel は VyOS 内部で動作するため、中間ブリッジが不要。

### ネットワークトポロジ

```
会場アップリンク (blackbox / proxy)
  │
  └─ vmbr0 [USB NIC]
       │
       └─ VyOS VM (r3)
            ├─ eth0 → vmbr0 (アップリンク)
            ├─ eth1 → vmbr_trunk (VLAN 11/30/40 トランク)
            └─ [内部] wstunnel (podman) → WireGuard (localhost:51820)

  vmbr_trunk [オンボード NIC]
       │
       └─ PoE スイッチ → AP / 配信 PC / スピーカー

  vmbr_trunk (native VLAN 11)
       │
       └─ ローカルサーバー CT
            └─ Grafana, rsyslog, nfcapd, SNMP Exporter
```

## VM / CT 構成

| 種別 | 名称 | OS | vCPU | RAM | ディスク | NIC | 役割 |
|------|------|-----|------|-----|---------|-----|------|
| VM | r3-vyos | VyOS | 2 | 6GB | SSD 8GB | eth0 (vmbr0), eth1 (vmbr_trunk) | ルーター、DNS/DHCP、BGP、NetFlow、wstunnel (podman) |
| CT | local-srv | Debian | 4 | 16GB | SSD 32GB + HDD 1TB マウント | eth0 (vmbr_trunk, VLAN 11) | Grafana, rsyslog, nfcapd, SNMP Exporter |

### リソース割り振りの根拠

- **r3-vyos (6GB, 2 vCPU)**: VyOS 自体は軽量だが、BGP・DNS/DHCP・Flow Accounting を同時処理するため RAM 6GB を確保。200名規模の DNS クエリと NetFlow 生成を余裕をもって処理。wstunnel は podman コンテナとして動作し、メモリ消費は数十 MB 程度で VyOS の 6GB 内に十分収まる。ディスクは設定とログ程度なので 8GB で十分
- **local-srv (16GB, 4 vCPU)**: Grafana + rsyslog + nfcapd + SNMP Exporter が同居し、最もリソースを消費。200名・100台以上のデバイスからの NetFlow v9 データのリアルタイム集計、Grafana の複数ダッシュボード同時描画、rsyslog の高スループット書き込みに対応。vCPU も 4 に増強し並列処理能力を確保。HDD 1TB を `/var/log` や nfcapd データディレクトリにマウントし長期保存に使用
- **Proxmox ホスト (3GB)**: Web UI のレスポンス向上とカーネルバッファに余裕を持たせる
- **予備 (7GB)**: 当日の追加 CT (キャプティブポータル、DNS キャッシュ/フィルタリング等) や、既存 CT の動的拡張に使用可能。旧設計の SoftEther CT (1GB) 廃止分が上乗せ

## wstunnel の役割分担

| 拠点 | 役割 | 配置 | 動作 |
|------|------|------|------|
| 自宅 | wstunnel **サーバー** | r1 配下 (192.168.10.4) | TCP 443 (WSS) で待ち受け。r1 の DNAT で外部からアクセス可能 |
| 会場 | wstunnel **クライアント** | r3 VyOS 上の podman コンテナ | プロキシ (HTTP CONNECT) 経由で自宅サーバーに接続し、UDP トンネルを確立 |

wstunnel は WireGuard の UDP パケットを WebSocket (TLS) にカプセル化する。会場側は VyOS 内部の podman コンテナとして動作するため、専用 CT や内部ブリッジが不要。WireGuard は `endpoint = 127.0.0.1:51820` で wstunnel に接続し、wstunnel が eth0 (vmbr0) 経由でプロキシを通過して自宅に到達する。

## WireGuard 経路の切替

上位レイヤー (BGP, IPv6, firewall) は常に wg0 に統一されており、下位トンネルの切替のみで対応する。wstunnel 方式ではデフォルトルートの変更が不要で、WireGuard endpoint の切替のみで済む。

### WireGuard 直接接続 (プロキシ解除時)

```
r3 VyOS (wg0) → eth0 (vmbr0) → USB NIC → blackbox → Internet → 自宅 r1
```

- WireGuard endpoint: `<自宅グローバル IP>:51820`
- wstunnel コンテナは停止

### wstunnel 経由 (プロキシ環境時)

```
r3 VyOS (wg0 → localhost:51820) → wstunnel (podman) → eth0 (vmbr0) → proxy CONNECT → 自宅 wstunnel → r1
```

- WireGuard endpoint: `127.0.0.1:51820`
- wstunnel コンテナが eth0 (vmbr0) 経由でプロキシを通過し、自宅に WebSocket (TLS) トンネルを確立
- **デフォルトルートの変更は不要** (wstunnel は VyOS 自身の eth0 から外に出る)

### 切替手順

```bash
# WG 直接 → wstunnel 経由に切り替え
# 1. wstunnel コンテナを起動 (VyOS CLI で設定済みの場合は restart)
restart container wstunnel

# 2. WireGuard endpoint を変更
set interfaces wireguard wg0 peer r1 endpoint '127.0.0.1:51820'
commit

# wstunnel 経由 → WG 直接に切り替え
# 1. WireGuard endpoint を変更
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
commit

# 2. wstunnel コンテナを停止 (任意)
stop container wstunnel
```

## 物理構成図

```
[Dell OptiPlex 3070 Micro]
  ┌──────────────────────────────┐
  │  Proxmox VE                  │
  │  ┌─────────────────────┐     │
  │  │ r3-vyos (VM)        │     │
  │  │  └─ wstunnel (podman)│     │
  │  └─────────────────────┘     │
  │  ┌───────────┐               │
  │  │ local-srv │               │
  │  │   (CT)    │               │
  │  └───────────┘               │
  ├──────────────────────────────┤
  │ [RJ45] Realtek RTL8111H     │──── トランク ──→ PoE スイッチ
  │ [USB]  2.5GbE NIC (テープ固縛)│──── アップリンク ──→ blackbox
  └──────────────────────────────┘
```
