# CLAUDE.md

## プロジェクト概要

BwAI in Kwansai 2026 のイベント会場ネットワークインフラの設計・構築リポジトリ。
会場のプロキシ環境に依存しない自前ネットワークを VPN トンネル経由で提供する。

## 技術スタック

- **ルーター**: VyOS (VM on Proxmox VE)
- **VPN**: WireGuard (プロキシ回避時は wstunnel over WebSocket/TLS)
- **ルーティング**: BGP (AS65001: 会場, AS65002: 自宅, AS64512: GCP VGW)
- **VLAN**: 11 (mgmt), 30 (staff+live), 40 (user)
- **監視**: Grafana, Prometheus SNMP Exporter, NetFlow v9, rsyslog
- **仮想基盤**: Proxmox VE (Dell OptiPlex 3070 Micro)
- **スクリプト**: Python 3 (VyOS API 経由の設定投入)

## リポジトリ構成

```
BwAI.md                  # ネットワーク構成図 (Mermaid)
docs/
  requirements/          # PRD, 要件定義
  design/                # アーキテクチャ設計書, VyOS 設計書, VLAN, スイッチ設計等
  investigation/         # 事前調査レポート
scripts/                 # VyOS 設定スクリプト (Python), ブートスクリプト
ServerStatusGet/         # サーバー状態取得ツール (開発中)
```

## コーディング規約

- ドキュメントは日本語で記述する
- コミットメッセージは日本語または英語 (既存のスタイルに合わせる)
- VyOS 設定スクリプトは Python 3 で記述し、VyOS API (`/configure`) 経由で投入する
- 設計書は Markdown 形式で `docs/design/` に配置する

## VyOS API 操作ルール

- VyOS API への設定投入・確認を指示された場合、**Python スクリプトを生成するのではなく、`curl` 等を使って Bash から直接 API を実行する**
- 投入前に内容を提示し確認を取ること（破壊的操作のため）

## VyOS REST API

### エンドポイント

| エンドポイント | メソッド | 用途 |
|---|---|---|
| `/configure` | POST | 設定の投入・削除 |
| `/retrieve` | POST | 設定値・状態の取得 |
| `/config-file` | POST | 設定ファイルの保存・読み込み |
| `/image` | POST | イメージ管理 |
| `/container-image` | POST | コンテナイメージ管理 |
| `/generate` | POST | 証明書・鍵の生成 |
| `/show` | POST | show コマンドの実行 |
| `/reset` | POST | リセット操作 |
| `/reboot` | POST | 再起動 |
| `/poweroff` | POST | シャットダウン |

### 認証

API キー認証を使用。VyOS 側で以下のように設定する:

```
set service https api keys id mykey key '<API_KEY>'
```

### ペイロード形式

#### `/configure` — 設定投入

```json
{
  "key": "<API_KEY>",
  "commands": [
    {"op": "set", "path": ["system", "time-zone", "Asia/Tokyo"]},
    {"op": "delete", "path": ["interfaces", "ethernet", "eth3", "vif", "11"]}
  ]
}
```

- **`op`**: `"set"` (作成/変更) または `"delete"` (削除)
- **`path`**: VyOS CLI のパス階層を文字列配列で指定

#### `/retrieve` — 設定・状態の取得

```json
{
  "key": "<API_KEY>",
  "op": "showConfig",
  "path": ["interfaces", "wireguard"]
}
```

`op` に指定可能な値:
- `"showConfig"` — 設定値の取得 (オプション: `"configFormat": "json"`)
- `"returnValues"` — 指定パスの値一覧を取得
- `"exists"` — 指定パスの存在確認

#### `/config-file` — 設定ファイル操作

```json
{
  "key": "<API_KEY>",
  "op": "save"
}
```

`op`: `"save"` または `"load"` (オプション: `"file": "/path/to/config"`)

#### `/show` — show コマンド実行

```json
{
  "key": "<API_KEY>",
  "op": "show",
  "path": ["ip", "route"]
}
```

#### `/generate` — 鍵・証明書生成

```json
{
  "key": "<API_KEY>",
  "op": "generate",
  "path": ["wireguard", "default-keypair"]
}
```

#### `/reset` — リセット操作

```json
{
  "key": "<API_KEY>",
  "op": "reset",
  "path": ["ip", "bgp", "10.255.0.2"]
}
```

## ネットワーク設計のポイント

- 会場上流がプロキシ環境のため、全トラフィックを WireGuard トンネルで自宅経由に迂回
- IPv6 は OPTAGE から DHCPv6-PD /64 を取得し、WireGuard 経由で会場に転送
- VLAN 40 (user) から VLAN 11 (mgmt) へのアクセスはデフォルト GW 以外拒否
- 通信ログ保存: NetFlow, DNS クエリログ, DHCP forensic log, NDP dump (法執行機関対応)
