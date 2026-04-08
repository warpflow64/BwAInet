# 会場スイッチ sw02 (Cisco ISR 1100) 実装例

> **前提**: 本ドキュメントは [`venue-switch.md`](./venue-switch.md) で定義したマルチベンダー共通設計 (VLAN モデル、ポート種別 T1〜T5、管理 IP ルール、STP 方針) の **Cisco ISR 1100 (C1111-8PLTELAWQ) による実装例** である。共通設計を先に読むこと。

## 概要

構築に使えるスイッチが不足しているため、手元の **Cisco ISR 1100 (C1111-8PLTELAWQ)** を L2 スイッチとして流用する。
LAN 側ポート (`GigabitEthernet0/1/0`〜`0/1/7`, `Wlan-GigabitEthernet0/1/8`) は Embedded Switch Module (ESM) のため標準の `switchport` 構文で動作する。WAN 側ポート (`GigabitEthernet0/0/0`, `0/0/1`) は `switchport` 非対応のため **使用しない (shutdown)**。

| 項目 | 値 |
|------|-----|
| ホスト名 | sw02 |
| 機種 | Cisco ISR 1100 (C1111-8PLTELAWQ) |
| OS | IOS XE 17.15 |
| 管理 VLAN | 11 |
| 管理 IP | 192.168.11.6/24 (Vlan11 SVI) |
| デフォルト GW | 192.168.11.1 (r3-vyos) |
| 位置付け | 現場判断で sw01 下位 / 並列どちらでも投入可能 |

### 設計方針: ESM ポートのみ使用

WAN ポート (Gi 0/0/0-1) を L2 化するには EVC (service instance) + bridge-domain 構文が必要だが、以下の理由から **ESM ポートのみで L2 構成** とする:

- sw01 と sw02 の接続順序・接続有無が現場まで確定しない
- EVC + bridge-domain の Vlan SVI 上 service instance は L3 (IP アドレス) と共存できず、管理 IP に BDI (Bridge-Domain Interface) が必要になり複雑化する
- bridge-domain 経由では MLD Snooping / IGMP Snooping が正常動作しない可能性がある

ESM ポート (Gi 0/1/0-7, Wlan-Gi 0/1/8) の 9 ポートで AP 収容・アップリンク・端末接続をすべてカバーする。

## 物理ポート構成 (C1111-8PLTELAWQ)

| ポート | 種別 | PoE | 速度 | 状態 | 備考 |
|--------|------|-----|------|------|------|
| Gi 0/0/0 | WAN (routed) | -- | 1G (SFP combo) | **shutdown** | switchport 非対応、未使用 |
| Gi 0/0/1 | WAN (routed) | -- | 1G | **shutdown** | switchport 非対応、未使用 |
| Gi 0/1/0 | LAN (ESM) | PoE+ | 1G | active | AP 直給電 |
| Gi 0/1/1 | LAN (ESM) | PoE+ | 1G | active | AP 直給電 |
| Gi 0/1/2 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/3 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/4 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/5 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/6 | LAN (ESM) | -- | 1G | **shutdown** | flex port (現場で有効化) |
| Gi 0/1/7 | LAN (ESM) | -- | 1G | **shutdown** | flex port (現場で有効化) |
| Wlan-Gi 0/1/8 | WLAN module | -- | 1G | active | 内蔵 WLAN モジュール |
| Cellular 0/2/0 | LTE | -- | -- | **shutdown** | ルーティング競合防止 |
| Cellular 0/2/1 | LTE | -- | -- | **shutdown** | 未使用 |

> **PoE 電源設計**: C1111-8PLTELAWQ の PoE 総バジェットは約 50W。Aironet 3800 は IEEE 802.3at (PoE+, 25.5W) のため、本体から直接給電できるのは `Gi 0/1/0-1` の 2 ポートのみ。それ以上の AP/PoE 機器は外部 PoE+ インジェクターを `Gi 0/1/2-5` に挿入して接続する。

## VLAN 定義

共通設計 ([`venue-switch.md`](./venue-switch.md) §1) と同じ。

| VLAN ID | 名称 | 用途 |
|---------|------|------|
| 11 | mgmt | NW 機器管理、AP 管理 IP (FlexConnect) |
| 30 | staff | 運営スタッフ、配信 PC |
| 40 | user | 来場者 |

## ポートアサイン (共通設計のポート種別にマッピング)

| ポート | 接続先 | Type | モード | VLAN | 備考 |
|--------|--------|------|--------|------|------|
| Gi 0/0/0 | -- | T5 | -- | -- | shutdown (未使用) |
| Gi 0/0/1 | -- | T5 | -- | -- | shutdown (未使用) |
| Gi 0/1/0 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect、PoE+ 直給電 |
| Gi 0/1/1 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect、PoE+ 直給電 |
| Gi 0/1/2 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect、PoE+ インジェクター経由 |
| Gi 0/1/3 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect、PoE+ インジェクター経由 |
| Gi 0/1/4 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect、PoE+ インジェクター経由 |
| Gi 0/1/5 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect、PoE+ インジェクター経由 |
| Gi 0/1/6 | 現場決定 | T1/T3 | trunk | 11,30,40 (native 11) | デフォルト shutdown、現場で有効化 |
| Gi 0/1/7 | 現場決定 | T1/T3 | trunk | 11,30,40 (native 11) | デフォルト shutdown、現場で有効化 |
| Wlan-Gi 0/1/8 | 内蔵 WLAN モジュール | T2 | trunk | 11,30,40 (native 11) | AP 同等の扱い |

## コンフィグ

```
! ============================================================
! sw02 Configuration (Cisco ISR 1100 / C1111-8PLTELAWQ, IOS XE 17.15)
! ESM ポートのみ使用、WAN ポートは shutdown
! ============================================================

! --- 基本設定 ---
hostname sw02
no ip http server
no ip http secure-server
lldp run

! --- VLAN 定義 ---
vlan 11
 name mgmt
vlan 30
 name staff
vlan 40
 name user

! --- 管理 SVI ---
interface Vlan11
 ip address 192.168.11.6 255.255.255.0
 no shutdown
!
interface Vlan30
 no ip address
 no shutdown
!
interface Vlan40
 no ip address
 no shutdown

ip default-gateway 192.168.11.1

! --- STP (MSTP — IEEE 802.1s) ---
spanning-tree mode mst
spanning-tree mst configuration
 name BWAI
 revision 1
spanning-tree mst 0 priority 8192

! ============================================================
! WAN ポート: 未使用 (shutdown)
! ============================================================

interface GigabitEthernet0/0/0
 no ip address
 shutdown
!
interface GigabitEthernet0/0/1
 no ip address
 shutdown

! ============================================================
! ESM ポート
! ============================================================

! Gi 0/1/0-5: Type T2 — AP trunk (FlexConnect、SSID ローカルスイッチング)
interface range GigabitEthernet0/1/0-5
 description AP
 switchport mode trunk
 switchport trunk allowed vlan 11,30,40
 switchport trunk native vlan 11
 spanning-tree portfast trunk
 spanning-tree bpduguard enable
 no shutdown

! Gi 0/1/6-7: Flex port — 現場で用途を決定
! デフォルトは trunk + shutdown。現場で no shutdown して使用
interface range GigabitEthernet0/1/6-7
 switchport mode trunk
 switchport trunk allowed vlan 11,30,40
 switchport trunk native vlan 11
 spanning-tree portfast trunk
 spanning-tree bpduguard enable
 storm-control multicast level 5.00
 shutdown

! Wlan-GigabitEthernet0/1/8: 内蔵 WLAN モジュール (T2 相当)
interface Wlan-GigabitEthernet0/1/8
 description AP
 switchport mode trunk
 switchport trunk allowed vlan 11,30,40
 switchport trunk native vlan 11
 spanning-tree portfast trunk
 spanning-tree bpduguard enable
 no shutdown

! ============================================================
! 未使用インタフェース
! ============================================================

interface Cellular0/2/0
 no ip address
 shutdown
!
interface Cellular0/2/1
 no ip address
 shutdown

! --- SSH ---
ip ssh version 2
line vty 0 4
 transport input ssh
 login local
line vty 5 14
 transport input ssh
 login local

end
```

## 現場での柔軟運用

### ケース 1: `Gi 0/1/6` をアップリンクとして有効化

sw01 や r3-vyos へのトランク接続に使用する場合。既に trunk 設定済みなので `no shutdown` のみ。

```
interface GigabitEthernet0/1/6
 no shutdown
```

> **注意**: アップリンクに使う場合は portfast trunk を外すことを推奨。上位スイッチとの BPDU 疎通を維持するため。
>
> ```
> interface GigabitEthernet0/1/6
>  no spanning-tree portfast trunk
>  no spanning-tree bpduguard enable
>  no shutdown
> ```

### ケース 2: `Gi 0/1/6` を access ポート (staff PC) に切り替え

```
interface GigabitEthernet0/1/6
 switchport mode access
 switchport access vlan 30
 spanning-tree portfast
 no shutdown
```

### ケース 3: `Gi 0/1/6` を access VLAN 40 (来場者セグメント) に切り替え

```
interface GigabitEthernet0/1/6
 switchport mode access
 switchport access vlan 40
 spanning-tree portfast
 no shutdown
```

### ケース 4: PoE トラブル時の PoE 無効化

```
interface GigabitEthernet0/1/0
 power inline never
```

## IPv6 マルチキャスト対策

### sw02 での RA Guard は不要

共通設計 ([`venue-switch.md`](./venue-switch.md) §7) では端末ポートに RA Guard を推奨しているが、sw02 では以下の理由から **RA Guard を設定しない**:

1. **クライアントは全員 AP 経由 (Wi-Fi)** — 不正 RA の遮断は WLC / AP (FlexConnect) 側で制御する
2. **sw02 の ESM ポートに直接繋がるのは AP・他スイッチ・r3-vyos** — いずれも RA を正当に中継する可能性がある。RA Guard で遮断すると正規の RA まで止まる
3. **アップリンク側 (r3-vyos) に IPv6 RA を送出するインタフェースがない** — 不正 RA のリスク自体が低い

RA Guard は WLC 側で SSID ごとに設定すること (FlexConnect: `ipv6 nd raguard` / WLC GUI: Wireless > WLAN > Advanced)。

### MLD Snooping

ISR 1100 ESM での MLD Snooping 対応は文書上不明確。実機で以下を確認:

```
ipv6 mld snooping ?
```

対応している場合は有効化を推奨:

```
ipv6 mld snooping
ipv6 mld snooping vlan 30
ipv6 mld snooping vlan 40
```

## 設計メモ

### ESM ポートのみ使用する理由

WAN ポート (Gi 0/0/0-1) の L2 化には EVC + bridge-domain が必要だが、実機検証の結果以下の問題が判明したため **ESM ポートのみで構成** とした:

1. **Vlan SVI に service instance を設定すると L3 (IP アドレス) が共存不可** — 管理 IP の付与に BDI (Bridge-Domain Interface) が必要になり、構成が複雑化する
2. **native VLAN の扱い** — EVC は `encapsulation dot1q <vlan-id>` で tagged フレームのみマッチする。対向が native VLAN でuntagged 送出する場合、`vlan dot1q tag native` の設定が対向側に必要
3. **sw01 との接続が保証されない** — 現場の配置次第で sw02 が sw01 に繋がらないケースがあり、WAN ポート EVC の前提が崩れる

ESM の 9 ポート (Gi 0/1/0-7 + Wlan-Gi 0/1/8) で AP 6 台 + flex 2 ポート + WLAN モジュール 1 ポートを収容でき、実用上十分である。

### C1111-8PLTELAWQ 固有の追加モジュール

C1111-8P に加えて以下のモジュールを搭載:

| モジュール | インタフェース | 本設計での扱い |
|-----------|---------------|---------------|
| LTE | Cellular 0/2/0, 0/2/1 | **shutdown** (ルーティング競合防止。全トラフィックは WireGuard トンネル経由) |
| WLAN | Wlan-GigabitEthernet 0/1/8 | AP 同等の trunk ポートとして使用 |

LTE をバックアップ回線として使用する場合は別途設計を追加すること。

### AP ポートを trunk (Type T2) にする意図

共通設計 ([`venue-switch.md`](./venue-switch.md) §2 Type T2) に従い、AP ポートを access VLAN 11 から **trunk (allowed 11,30,40, native 11)** に変更している。これにより AP は以下のように動作する:

- 管理 IP は native VLAN 11 (untagged) で r3-vyos の DHCP プール (.100--.199) から取得
- クライアントトラフィックは AP 側 (FlexConnect / スタンドアロン) で SSID ごとに VLAN 30 / 40 タグを付与してスイッチへ送出
- WLC 3504 は設定管理と認証のみを担当 (トラフィックパスから外れる)

### 論理的な位置付け (未確定 --- 現場柔軟)

sw02 は **「ESM のアップリンクポート (Gi 0/1/6-7) 経由で sw01 の下位、または r3-vyos 直結の並列スイッチとして投入できる」** 前提で設計している。どちらで使っても設定は変わらない:

- **下位配置 (sw01 ダウンリンク)**: `Gi 0/1/6` を sw01 の Ge ポートにトランク接続
- **並列配置 (r3-vyos 直結)**: `Gi 0/1/6` を Proxmox ホストの追加 NIC / VLAN 対応ブリッジに接続
  - ただし BPDU が疎通する経路構成では STP ループに注意。`spanning-tree mode mst` + MST リージョン設定 (name `BWAI`, revision `1`) を sw01 と揃えていれば MSTP で収束する

## 実機検証チェックリスト

- [ ] sw02 `Vlan11` (192.168.11.6) から `192.168.11.1` (r3-vyos) に ping が通る
- [ ] 自宅環境から sw02 へ SSH ログインできる
- [ ] AP (Aironet 3800) が native VLAN 11 経由で管理 IP (192.168.11.100--.199) を DHCP 取得できる
- [ ] AP の SSID ごとに VLAN 30 / 40 タグ付きトラフィックが送出され、上位経由で r3-vyos に到達する
- [ ] VLAN 30/40 の DHCP リースが端末で取得できる
- [ ] `show spanning-tree mst configuration` で name `BWAI`, revision `1` が表示される
- [ ] `show spanning-tree mst 0` で priority 8192 が設定されている
- [ ] `ipv6 mld snooping ?` で ESM での MLD Snooping 対応可否を確認
- [ ] `show mac address-table` で AP / 上位スイッチの MAC が学習されている

## 関連ドキュメント

- [`venue-switch.md`](./venue-switch.md) --- 会場スイッチ共通設計 (マルチベンダー)
- [`venue-switch1.md`](./venue-switch1.md) --- sw01 (FS) 実装例
- [`mgmt-vlan-address.md`](./mgmt-vlan-address.md) --- 管理 VLAN アドレス割当表

## 参考文献

- [Cisco 1000 Series Software Configuration Guide --- Configuring Ethernet Switch Ports (XE 17)](https://www.cisco.com/c/en/us/td/docs/routers/access/isr1100/software/configuration/xe-17/isr1100-sw-config-xe-17/configuring_ethernet_switchports.html)
- [Cisco 1000 Series Software Configuration Guide --- Configuring Bridge Domain Interfaces (XE 17)](https://www.cisco.com/c/en/us/td/docs/routers/access/isr1100/software/configuration/xe-17/isr1100-sw-config-xe-17/bdi_isr1k.html)
