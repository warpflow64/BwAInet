# 通信ログ保存設計 (法執行機関対応)

## 1. 目的と記録ポリシー

法執行機関からの照会に対し、通信記録を適切に提出できる体制を整備する。

### 基本方針

- IP ペイロード (通信内容) は**記録しない**
- 通信メタデータ (誰が・いつ・どこと) のみを記録
- 全ログを相互に紐付けて追跡可能にする
- 保存期間: **180 日**

### 記録対象と非記録対象

| 記録する | 記録しない |
|---|---|
| 5-tuple (src/dst IP, src/dst port, protocol) | IP ペイロード (通信内容) |
| タイムスタンプ, バイト数, パケット数 | HTTP URL / ヘッダ / ボディ |
| DNS クエリ名 (qname) + 応答コード | DNS 応答レコード値 |
| DHCP リース (IP ↔ MAC ↔ hostname) | |
| NDP テーブル (IPv6 ↔ MAC) | |

## 2. ログ相関モデル

### ログ種別と役割

```
[誰が]
  VyOS DHCP リースログ    → timestamp + IPv4 ↔ MAC ↔ hostname
  NDP テーブルダンプ       → timestamp + IPv6 ↔ MAC (全デバイス)
  VyOS DHCPv6 リースログ  → timestamp + IPv6 ↔ DUID (Windows/macOS のみ)

[何を調べた]
  VyOS DNS クエリログ     → timestamp + client IP + qname + rcode

[どこと通信した]
  NetFlow v9              → timestamp + 5-tuple + bytes/packets
```

### 共通結合キー

**タイムスタンプ + IP アドレス + MAC アドレス**

### 追跡例

「2026-08-10 14:30 に example.com にアクセスしたデバイスは？」

1. DNS クエリログから `example.com` を引いた client IP を特定
2. NetFlow から当該 IP の通信フローを確認
3. DHCP リースログ / NDP ダンプから IP → MAC → hostname を特定

## 3. VyOS DNS Forwarding 設定

VyOS 内蔵の `service dns forwarding` (PowerDNS Recursor) を使用。Unbound は廃止。

```
# DNS フォワーディング
set service dns forwarding listen-address 192.168.11.1
set service dns forwarding listen-address 192.168.30.1
set service dns forwarding listen-address 192.168.40.1
set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding system

# クエリログ有効化 (法執行対応)
set service dns forwarding options 'log-common-errors=yes'
set service dns forwarding options 'quiet=no'
set service dns forwarding options 'logging-facility=0'
```

PowerDNS Recursor のログは syslog 経由で出力される。`quiet=no` でクエリごとに以下のフォーマットで記録:

```
timestamp client_ip query_name query_type rcode
```

## 4. VyOS DHCP 設定 + Forensic Log

VyOS 内蔵の `service dhcp-server` (内部 Kea) を使用。別サーバーの Kea は廃止。

### DHCPv4

```
# VLAN 30 (staff + live)
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 range 0 start 192.168.30.100
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 range 0 stop 192.168.30.254
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 default-router 192.168.30.1
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 name-server 192.168.30.1
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 lease 3600

# VLAN 40 (user)
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 range 0 start 192.168.40.100
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 range 0 stop 192.168.43.254
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 default-router 192.168.40.1
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 name-server 192.168.40.1
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 lease 3600
```

### DHCPv6

```
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1000 stop <prefix>::ffff
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1

set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1:0 stop <prefix>::1:ffff
set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1
```

※ iOS/Android は DHCPv6 IA_NA 非対応のため SLAAC でアドレスを取得する。DHCPv6 は Windows/macOS 用。

### Forensic Log (Kea hook)

VyOS 内蔵 Kea の設定ファイル (`/etc/kea/kea-dhcp4.conf`) に直接 hook を追加:

```json
{
    "hooks-libraries": [
        {
            "library": "/usr/lib/kea/hooks/libdhcp_legal_log.so",
            "parameters": {
                "path": "/var/log/kea",
                "name": "kea-legal"
            }
        }
    ]
}
```

記録内容: タイムスタンプ, リースタイプ (assign/renew/release), IP, MAC, hostname, lease duration

## 5. VyOS Flow-Accounting 設定 (NetFlow v9)

```
set system flow-accounting interface eth0.30
set system flow-accounting interface eth0.40
set system flow-accounting interface wg0
set system flow-accounting netflow version 9
set system flow-accounting netflow server 192.168.11.10 port 2055
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-active 120
set system flow-accounting netflow timeout flow-inactive 15
set system flow-accounting netflow source-ip 192.168.11.1
```

対象インターフェース:
- `eth0.30` — staff + live トラフィック
- `eth0.40` — user トラフィック
- `wg0` — VPN トンネル経由の全トラフィック

※ `eth0.11` (mgmt) は対象外

## 6. VyOS RA 設定

IPv6 アドレス追跡のため、SLAAC と DHCPv6 を併用する。

```
# VLAN 30
set interfaces ethernet eth0 vif 30 ipv6 address autoconf
set service router-advert interface eth0.30 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth0.30 managed-flag true
set service router-advert interface eth0.30 other-config-flag true
set service router-advert interface eth0.30 name-server <prefix>::1

# VLAN 40
set service router-advert interface eth0.40 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth0.40 managed-flag true
set service router-advert interface eth0.40 other-config-flag true
set service router-advert interface eth0.40 name-server <prefix>::1
```

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 (iOS/Android 用) |
| M (managed) | 1 | DHCPv6 アドレス割り当て (Windows/macOS 用) |
| O (other-config) | 1 | DHCPv6 で DNS 等の追加情報取得 (iOS も対応) |
| RDNSS | 設定 | Android の DNS 解決に必須 (DHCPv6 非対応のため) |

### iOS/Android の DHCPv6 非対応について

| OS | DHCPv6 IA_NA | SLAAC | RDNSS |
|---|---|---|---|
| Windows 11 | 対応 | 対応 | 対応 |
| macOS 15 | 対応 | 対応 | 対応 |
| iOS 18 | **非対応** | 対応 | 対応 |
| Android 15 | **非対応** | 対応 | 対応 (必須) |

iOS/Android は SLAAC のみで IPv6 アドレスを取得するため、NDP テーブルダンプで IPv6 ↔ MAC の対応を記録する必要がある。

## 7. NDP テーブルダンプ

1 分間隔の cron で VyOS の IPv6 neighbor テーブルを記録。iOS/Android を含む全デバイスの IPv6 ↔ MAC 対応を取得する。

### スクリプト (`/config/scripts/ndp-dump.sh`)

```bash
#!/bin/bash
# NDP テーブルダンプ (IPv6 ↔ MAC 記録)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ip -6 neigh show | while read -r line; do
    echo "${TIMESTAMP} ${line}"
done | logger -t ndp-dump -p local1.info
```

### cron 設定

```
set system task-scheduler task ndp-dump interval 1m
set system task-scheduler task ndp-dump executable path /config/scripts/ndp-dump.sh
```

### 出力例

```
2026-08-10T14:30:00Z fe80::1a2b:3c4d:5e6f:7890 dev eth0.40 lladdr aa:bb:cc:dd:ee:ff REACHABLE
2026-08-10T14:30:00Z 2001:db8::abcd dev eth0.30 lladdr 11:22:33:44:55:66 STALE
```

## 8. nfcapd コレクター構成 (Local Server)

ローカルサーバー (192.168.11.10) で nfcapd を稼働させ、VyOS からの NetFlow を受信。

### インストール

```bash
apt install nfdump
```

### systemd ユニット (`/etc/systemd/system/nfcapd.service`)

```ini
[Unit]
Description=NetFlow Capture Daemon
After=network.target

[Service]
ExecStart=/usr/bin/nfcapd -w -D -l /var/log/nfcapd -p 2055 -T all -t 300
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

パラメータ:
- `-l /var/log/nfcapd` — 保存ディレクトリ
- `-p 2055` — 受信ポート
- `-T all` — 全拡張フィールドを記録
- `-t 300` — 5 分間隔でファイルローテーション

## 9. 転送・アーカイブ (rsyslog → GCE → S3)

### rsyslog 転送設定 (VyOS → Local Server → GCE)

VyOS のログ (DNS クエリ、DHCP forensic、NDP ダンプ) は syslog 経由で Local Server に転送し、さらに GCE に転送。

```
# VyOS → Local Server
set system syslog host 192.168.11.10 facility all level info

# Local Server rsyslog.conf → GCE 転送 (既存パイプライン活用)
# *.* @@<gce-ip>:514
```

### nfcapd ファイル転送 (rsync)

```bash
# cron (15 分間隔)
*/15 * * * * rsync -az /var/log/nfcapd/ <gce-user>@<gce-ip>:/var/log/nfcapd/
```

### S3 ライフサイクルポリシー

```json
{
    "Rules": [
        {
            "ID": "log-retention-180d",
            "Status": "Enabled",
            "Filter": { "Prefix": "logs/" },
            "Expiration": { "Days": 180 }
        }
    ]
}
```

## 10. 保存期間とローテーション

| ログ種別 | ローカル保存 | GCE 保存 | S3 保存 |
|---|---|---|---|
| NetFlow (nfcapd) | 30 日 | 90 日 | 180 日 |
| DNS クエリログ | 30 日 | 90 日 | 180 日 |
| DHCP forensic log | 30 日 | 90 日 | 180 日 |
| NDP テーブルダンプ | 30 日 | 90 日 | 180 日 |

ローカルのローテーション:

```bash
# /etc/logrotate.d/compliance-logs
/var/log/nfcapd/*.nfcapd {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
```

## 11. 照会対応手順

### nfdump による NetFlow 検索

```bash
# 特定 IP の全通信フロー
nfdump -R /var/log/nfcapd -o long "src ip 192.168.40.123 or dst ip 192.168.40.123"

# 特定時間帯の通信
nfdump -R /var/log/nfcapd -t 2026/08/10.14:00:00-2026/08/10.15:00:00

# 特定ポートへの通信 (例: HTTPS)
nfdump -R /var/log/nfcapd "dst port 443 and src ip 192.168.40.123"

# 通信量トップ 10 (IP 別)
nfdump -R /var/log/nfcapd -s srcip -n 10
```

### DNS クエリログ検索

```bash
# 特定ドメインへのクエリを検索
grep "example.com" /var/log/syslog | grep "dns-forwarding"

# 特定クライアントのクエリ
grep "192.168.40.123" /var/log/syslog | grep "dns-forwarding"
```

### DHCP リースログ検索

```bash
# 特定 MAC アドレスのリース履歴
grep "aa:bb:cc:dd:ee:ff" /var/log/kea/kea-legal*.txt

# 特定 IP のリース履歴
grep "192.168.40.123" /var/log/kea/kea-legal*.txt
```

### NDP ダンプ検索

```bash
# 特定 MAC の IPv6 アドレス履歴
grep "aa:bb:cc:dd:ee:ff" /var/log/syslog | grep "ndp-dump"

# 特定 IPv6 アドレスの MAC 特定
grep "2001:db8::abcd" /var/log/syslog | grep "ndp-dump"
```

### 総合追跡 (IP → デバイス → 全通信)

```bash
# Step 1: 時刻から IP を使っていた MAC を特定
grep "192.168.40.123" /var/log/kea/kea-legal*.txt

# Step 2: その MAC の IPv6 アドレスも特定
grep "<mac-address>" /var/log/syslog | grep "ndp-dump"

# Step 3: 両 IP の DNS クエリを取得
grep "192.168.40.123\|<ipv6-address>" /var/log/syslog | grep "dns-forwarding"

# Step 4: 両 IP の NetFlow を取得
nfdump -R /var/log/nfcapd "src ip 192.168.40.123 or dst ip 192.168.40.123"
