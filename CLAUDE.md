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

## VyOS API 操作

- VyOS API への操作は skill（`/vyos-show`, `/vyos-retrieve`, `/vyos-configure`, `/vyos-save`）を使用する
- Python スクリプトを生成するのではなく、`curl` で Bash から直接 API を実行する
- 設定投入前に内容を提示し確認を取ること（破壊的操作のため）
- skill の詳細は `.claude/skills/vyos-*/SKILL.md` を参照

## ネットワーク設計のポイント

- 会場上流がプロキシ環境のため、全トラフィックを WireGuard トンネルで自宅経由に迂回
- IPv6 は OPTAGE から DHCPv6-PD /64 を取得し、WireGuard 経由で会場に転送
- VLAN 40 (user) から VLAN 11 (mgmt) へのアクセスはデフォルト GW 以外拒否
- 通信ログ保存: NetFlow, DNS クエリログ, DHCP forensic log, NDP dump (法執行機関対応)
