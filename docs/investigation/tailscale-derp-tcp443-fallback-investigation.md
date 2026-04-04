# Tailscale DERP TCP 443 フォールバック機構 調査レポート

## 調査目的

会場ネットワークの上流がプロキシ環境であり、現在 SoftEther over WireGuard でプロキシ回避を計画している。Tailscale の TCP 443 フォールバック機構 (DERP) が代替案として有効かを技術的に評価する。

## 1. DERP (Designated Encrypted Relay for Packets) プロトコル

### 概要

DERP は Tailscale が開発した独自のリレープロトコルで、直接の P2P 接続 (UDP WireGuard) が確立できない場合の「最終手段」として機能する。curve25519 公開鍵をアドレスとして使用し、TCP 443 (HTTPS) 上で暗号化済み WireGuard パケットを中継する。

ソースコードのコメントより:
> "DERP is used by Tailscale nodes to proxy encrypted WireGuard packets through the Tailscale cloud servers when a direct path cannot be found or opened. DERP is a last resort."

### プロトコル仕様

- **最大パケットサイズ**: 64 KB (`MaxPacketSize = 64 << 10`)
- **マジックナンバー**: `DERP🔑` (8 bytes: `0x44 45 52 50 f0 9f 94 91`)
- **プロトコルバージョン**: 2 (v2 では受信パケットに送信元アドレスが付加)
- **フレームヘッダ**: 5 bytes (1 byte フレームタイプ + 4 byte big-endian uint32 長さ)
- **鍵長**: 32 bytes (curve25519)
- **KeepAlive**: 60 秒間隔

### フレームタイプ一覧

| フレーム | コード | 用途 |
|----------|--------|------|
| FrameServerKey | 0x01 | サーバー公開鍵 (接続時) |
| FrameClientInfo | 0x02 | クライアント認証 (NaCl box 暗号化 JSON) |
| FrameServerInfo | 0x03 | サーバー情報応答 |
| FrameSendPacket | 0x04 | パケット送信 (32B 宛先鍵 + データ) |
| FrameRecvPacket | 0x05 | パケット受信 (v2: 32B 送信元鍵 + データ) |
| FrameKeepAlive | 0x06 | 接続維持 |
| FrameNotePreferred | 0x07 | ホームノード指定 |
| FramePeerGone | 0x08 | ピア切断通知 |
| FramePeerPresent | 0x09 | ピア接続通知 |
| FrameForwardPacket | 0x0a | メッシュ間転送 |
| FramePing / FramePong | 0x12 / 0x13 | RTT 測定 |
| FrameHealth | 0x14 | ヘルスチェック |

### プロトコルフロー

```
1. クライアントが TCP/TLS 接続を確立
2. HTTP GET /derp + Upgrade: DERP ヘッダーを送信
3. サーバーが 101 Switching Protocols で応答
4. サーバーが FrameServerKey を送信 (8B magic + 32B 公開鍵)
5. クライアントが FrameClientInfo を送信 (32B 公開鍵 + NaCl box 暗号化 JSON)
6. サーバーが FrameServerInfo を送信
7. 以降、FrameSendPacket / FrameRecvPacket でパケットを中継
```

**Fast-Start 最適化**: `Derp-Fast-Start: 1` ヘッダーにより、サーバーの HTTP 101 応答を省略して 1 RTT 削減可能。

## 2. フォールバック機構の詳細

### 接続確立の優先順位

Tailscale は以下の順序で接続を試みる:

```
1. DERP リレー経由 (初期接続、常に最初に確立)
2. 直接接続の試行 (STUN + NAT traversal → UDP WireGuard)
3. 成功: 直接接続にアップグレード
4. 失敗: Peer Relay を試行 (近隣ノード経由の UDP WireGuard)
5. 全て失敗: DERP リレーを継続使用
```

### 検出メカニズム

- **初期状態**: 全ての接続は DERP 経由で開始される (UDP が使えるかどうかに関係なく)
- **NAT traversal**: STUN (UDP/3478) でパブリック IP とNAT タイプを検出
- **直接接続試行**: DERP 経由でエンドポイント情報を交換し、UDP ホールパンチングを実行
- **定期再チェック**: 直接接続やPeer Relay への昇格を定期的に再試行

### 重要な設計思想

DERP は「UDP が使えないときに TCP にフォールバックする」のではなく、「最初から TCP (DERP) で接続し、UDP 直接接続が可能ならアップグレードする」というアプローチである。これにより接続確立の遅延が最小化される。

## 3. TCP トランスポート層の詳細

### TLS/HTTPS ラッピング

DERP クライアントは以下の手順で接続を確立する:

1. **TCP 接続確立** → TLS ハンドシェイク (TLS 1.3 推奨)
2. **Meta Certificate**: TLS 証明書チェーンにサーバーの DERP 公開鍵を含む追加証明書を付加。TLS 1.3 では証明書チェーンが暗号化されるため、DERP 公開鍵はネットワーク観測者に見えない
3. **HTTP Upgrade**: `GET /derp` + `Upgrade: DERP` + `Connection: Upgrade` ヘッダー
4. **プロトコル切替**: 101 Switching Protocols 後、バイナリ DERP フレーミングに移行

### ファイアウォール/DPI からの見え方

ソースコードのコメントより:
> "This makes DERP look exactly like WebSockets. A server can implement DERP over HTTPS and even if the TLS connection intercepted using a fake root CA, unless the interceptor knows how to detect DERP packets, it will look like a web socket."

つまり:
- **TLS 暗号化済み**: 外部からはペイロードが見えない
- **WebSocket に酷似**: HTTP Upgrade パターンが WebSocket と同じ
- **TCP 443**: 通常の HTTPS トラフィックと区別困難
- **SSL MITM 環境でも**: DERP 固有のパケットパターンを知らなければ WebSocket に見える

### TCP パラメータ設定

| パラメータ | 値 | 理由 |
|-----------|-----|------|
| TCP Keep-Alive | 10 分 | モバイルバッテリー消費軽減 |
| TCP User Timeout | 15 秒 | 切断の迅速検出 |
| MPTCP | 無効 | ソケットタイムアウトとの非互換 |

### WebSocket 代替トランスポート

ブラウザ環境向けに、`/derp` への WebSocket 接続も実装されている。Go 以外のクライアント (JS) やプロキシ制約がある環境で使用される。

## 4. HTTP CONNECT プロキシ対応

### 実装状況: 対応済み

Tailscale のソースコード (`derp/derphttp/derphttp_client.go`) に `dialNodeUsingProxy()` メソッドが実装されており、HTTP CONNECT メソッドによるプロキシトンネリングを正式にサポートしている。

### 動作フロー

```
1. dialNode() が呼ばれる
2. feature.HookProxyFromEnvironment で環境変数からプロキシ URL を検出
3. プロキシが検出された場合、dialNodeUsingProxy() を呼び出し
4. プロキシサーバーに TCP 接続
5. "CONNECT <derp-server>:443 HTTP/1.1" を送信
6. Proxy-Authorization ヘッダー (必要な場合)
7. プロキシから 200 OK を受信
8. 確立された TCP トンネル上で TLS → DERP プロトコルを実行
```

### 実装コード (抜粋)

```go
// dialNodeUsingProxy connects to n using a CONNECT to the HTTP(s) proxy
func (c *Client) dialNodeUsingProxy(ctx context.Context, n *tailcfg.DERPNode, proxyURL *url.URL) (_ net.Conn, err error) {
    // プロキシへの接続 (HTTP or HTTPS)
    if pu.Scheme == "https" {
        proxyConn, err = d.DialContext(ctx, "tcp", net.JoinHostPort(pu.Hostname(), "443"))
    } else {
        proxyConn, err = d.DialContext(ctx, "tcp", net.JoinHostPort(pu.Hostname(), "80"))
    }
    // CONNECT メソッド送信
    fmt.Fprintf(proxyConn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", target, target, authHeader)
    // レスポンス確認
    res, err := http.ReadResponse(br, nil)
    if res.StatusCode != 200 {
        return nil, fmt.Errorf("invalid response status from HTTP proxy")
    }
    return proxyConn, nil
}
```

### 設定方法

`tailscaled` が systemd で起動されるため、ユーザーシェルの環境変数は参照されない。`/etc/default/tailscaled` に以下を設定する必要がある:

```bash
HTTPS_PROXY="http://proxy-host:port"
HTTP_PROXY="http://proxy-host:port"
```

### 既知の問題

- systemd 経由で起動する場合、ユーザーセッションの環境変数が自動で引き継がれない (GitHub Issue #10235)
- SSL MITM プロキシ環境では DERP レイテンシチェックが正常動作しない場合がある (Issue #4377)
- SOCKS5 プロキシ経由の場合、DERP サーバーへの接続が不安定になるケースが報告されている (Issue #12655)

## 5. パフォーマンスへの影響

### TCP-over-TCP 問題

DERP は TCP (TLS) 上で WireGuard パケットを中継する。WireGuard 自体は通常 UDP だが、DERP 経由の場合:

```
アプリケーション TCP データ
  → WireGuard 暗号化 (本来 UDP ペイロード)
    → DERP フレーミング
      → TLS 暗号化
        → TCP セグメント
          → (プロキシ CONNECT トンネル経由の場合、さらに TCP)
```

**TCP-over-TCP の影響**:
- TCP ヘッドオブライン・ブロッキング: 外側 TCP で 1 パケットがドロップすると、後続の全パケットが再送まで停止
- TCP の再送タイマーが二重に動作し、パケットロス時のリカバリが遅延
- ただし、DERP が中継するのは WireGuard の暗号化済みペイロードであり、内部の TCP セッションの ACK/再送は WireGuard レベルで処理される

### レイテンシオーバーヘッド

| 接続タイプ | 追加レイテンシ | スループット |
|-----------|-------------|------------|
| 直接 UDP WireGuard | ベースライン | 最大 |
| DERP リレー (同一リージョン) | +5-20ms | 制限あり (レート制限) |
| DERP リレー (クロスリージョン) | +50-200ms | 制限あり |
| DERP + HTTP CONNECT プロキシ | +10-30ms (追加) | さらに低下 |

### Tailscale 公式の見解

> "DERP servers are reliable but have limited quality of service (QoS) characteristics, so they are generally slower than direct connections and may offer lower maximum throughput."

### レート制限

DERP サーバーはトークンバケットアルゴリズムによるレート制限を実施。`ServerInfo` でバイト/秒とバーストパラメータがクライアントに通知され、クライアント側でサイレントにパケットドロップする。

## 6. セルフホスト / スタンドアロン利用

### DERP サーバーのオープンソース状況

DERP サーバーは **完全にオープンソース** (BSD-3-Clause ライセンス)。

- **リポジトリ**: `github.com/tailscale/tailscale` 内の `cmd/derper/`
- **Go パッケージ**: `tailscale.com/derp`, `tailscale.com/derp/derphttp`

### セルフホスト DERP サーバー

Tailscale の `derper` コマンドで自前の DERP サーバーを立てられる:

```bash
go install tailscale.com/cmd/derper@latest
derper --hostname=derp.example.com --certmode=letsencrypt
```

**主要フラグ**:
| フラグ | デフォルト | 説明 |
|--------|-----------|------|
| `--hostname` | (必須) | TLS 証明書のホスト名 |
| `--certmode` | letsencrypt | 証明書モード (letsencrypt/manual) |
| `--verify-clients` | false | Tailnet メンバーのみに制限 |
| `--mesh-psk-file` | - | メッシュ認証の事前共有鍵 |
| `--tcp-user-timeout` | 15s | TCP 切断検出タイムアウト |
| `--accept-connection-limit` | - | 接続レート制限 |

**必要ポート**:
- TCP/443: DERP リレー (HTTPS)
- TCP/80: キャプティブポータル検出 / Let's Encrypt
- UDP/3478: STUN

### Headscale との連携

Headscale (オープンソースの Tailscale コントロールプレーン代替) には組み込み DERP サーバーが含まれる:

```yaml
derp:
  server:
    enabled: true
    ipv4: 198.51.100.1
    ipv6: 2001:db8::1
```

### Docker デプロイ

複数のコミュニティプロジェクトが Docker イメージを提供:
- `n0ptr/Tailscale-DERP-Docker`: `--verify-clients` 対応
- `fredliang44/derper-docker`: マルチアーキテクチャ対応 (amd64, arm64, armv7)
- `Zwlin98/derper`: Nginx Proxy Manager 連携

### 制約事項

- DERP サーバーは **ベアメタル推奨** (NAT/ロードバランサー背後での動作が不安定)
- STUN (UDP/3478) も併せて公開する必要がある
- `--verify-clients` を使用しない場合、任意のユーザーがリレーを利用可能

### 本プロジェクトでの利用可能性

DERP プロトコル自体はオープンソースだが、**Tailscale クライアント (または Headscale) のエコシステムに依存する**。VyOS の WireGuard と直接統合することはできない。DERP を使うには Tailscale ネットワーク (tailnet) を構築するか、Headscale を自前運用する必要がある。

## 7. Tailscale にインスパイアされた代替手段

### 7.1 wstunnel (推奨度: 高)

**GitHub**: `github.com/erebe/wstunnel`

WebSocket または HTTP/2 上でトラフィックをトンネルするツール。Rust 実装で高性能。

**特徴**:
- WebSocket / HTTP/2 対応
- HTTP CONNECT プロキシ対応 (`-p` / `--http-proxy` フラグ)
- UDP トンネリング対応 (WireGuard と直接連携可能)
- 1 Gbps を 1 コアで飽和させる性能 (CPU 使用率 5% 未満)
- レイテンシ追加: LAN +1-2ms、大陸間 +5-15ms
- UDP パケット境界を保持 (TCP meltdown を軽減)

**WireGuard 連携例**:

```bash
# サーバー側
wstunnel server --restrict-to localhost:51820 wss://[::]:443

# クライアント側
wstunnel client -L 'udp://51820:localhost:51820?timeout_sec=0' wss://my.server.com:443

# プロキシ経由
wstunnel client --http-proxy proxy-host:3128 \
  -L 'udp://51820:localhost:51820?timeout_sec=0' wss://my.server.com:443
```

**WireGuard 側の設定変更**:
- MTU を 1300-1400 に下げる (WebSocket + TLS オーバーヘッド分)
- `PersistentKeepalive` を設定
- wstunnel サーバーへの静的ルートを追加 (トラフィックループ回避)

### 7.2 ProxyGuard (eduVPN)

**用途**: WireGuard の UDP パケットを TCP に変換

**特徴**:
- 独自プロトコル UoTLV/1 (UDP over TCP Length Value Version 1) を使用
- WebSocket のようなハンドシェイク後、直接 TCP 通信に「アップグレード」してオーバーヘッドを最小化
- Go 実装でセキュリティ監査が容易
- 管理者権限不要
- リバースプロキシ (Apache/Nginx) の背後に配置可能

### 7.3 udp2raw

UDP パケットを偽装 TCP/ICMP パケットとして送信。DPI 回避に有効だが、プロキシ CONNECT には非対応。

### 7.4 SoftEther VPN (現行計画)

**特徴**:
- HTTPS (TCP 443) 上でトンネルを確立
- HTTP CONNECT プロキシ対応
- 並列伝送機構 (最大 32 チャネル) で遅延ネットワークでのスループット最適化
- 長い実績と安定性

## 8. 本プロジェクトへの適用評価

### 比較表

| 項目 | SoftEther (現行計画) | Tailscale DERP | wstunnel + WireGuard |
|------|---------------------|---------------|---------------------|
| プロキシ CONNECT 対応 | ○ | ○ (実装済み) | ○ |
| TCP 443 偽装 | ○ (HTTPS) | ○ (HTTPS/WebSocket) | ○ (WebSocket/HTTP2) |
| VyOS WireGuard 連携 | △ (別レイヤー) | x (Tailnet 必須) | ○ (透過的) |
| 自前サーバーのみで完結 | ○ | △ (Headscale 必要) | ○ |
| 導入の複雑さ | 中 (CT + 設定) | 高 (エコシステム導入) | 低 (バイナリ 1 つ) |
| パフォーマンス | 高 (並列伝送) | 中 (レート制限あり) | 高 (Rust, 1Gbps/core) |
| SSL MITM 耐性 | △ | △ | △ |
| 運用実績 | 豊富 | 豊富 (大規模) | 中 |
| ライセンス | Apache 2.0 | BSD-3-Clause | BSD-3-Clause |

### 推奨

1. **現行計画 (SoftEther) を維持**: プロキシ CONNECT 対応、並列伝送、長い実績。既に設計済みの CT 構成を活かせる

2. **代替候補として wstunnel を検討**: SoftEther より軽量で、VyOS の WireGuard と直接連携可能。単一バイナリで導入が簡単。プロキシ環境での動作も確認されている。wstunnel サーバーを自宅側に設置し、会場側から `wstunnel client --http-proxy` でプロキシ経由接続する構成が最もシンプル

3. **Tailscale DERP は不採用**: DERP 自体はオープンソースで技術的に優れているが、Tailscale/Headscale のエコシステム全体が必要になる。既存の VyOS + WireGuard + BGP アーキテクチャとの統合コストが高すぎる

### wstunnel 導入時の構成案

```
会場 (プロキシ環境)
  wstunnel client
    --http-proxy <venue-proxy>:8080
    -L 'udp://51820:localhost:51820?timeout_sec=0'
    wss://home.example.com:443
  → VyOS WireGuard (Endpoint = 127.0.0.1:51820)

自宅
  wstunnel server
    --restrict-to localhost:51820
    wss://[::]:443
  → VyOS WireGuard (ListenPort = 51820)
```

この構成であれば、プロキシ解除時は wstunnel を停止して WireGuard の Endpoint を直接自宅 IP に変更するだけで済む。

## Sources

- [Tailscale: How it works](https://tailscale.com/blog/how-tailscale-works)
- [Connection types - Tailscale Docs](https://tailscale.com/kb/1257/connection-types)
- [What firewall ports should I open? - Tailscale Docs](https://tailscale.com/docs/reference/faq/firewall-ports)
- [DERP Relay System - DeepWiki](https://deepwiki.com/tailscale/tailscale/4.4-derp-relay-system)
- [DERP servers - Tailscale Docs](https://tailscale.com/docs/reference/derp-servers)
- [derp package - Go Packages](https://pkg.go.dev/tailscale.com/derp)
- [Tailscale DERP HTTP Client Source](https://github.com/tailscale/tailscale/blob/main/derp/derphttp/derphttp_client.go)
- [tailscaled HTTP_PROXY issue #10235](https://github.com/tailscale/tailscale/issues/10235)
- [FR: Use tailscale over local http proxy #8017](https://github.com/tailscale/tailscale/issues/8017)
- [DERP - Headscale](https://headscale.net/stable/ref/derp/)
- [wstunnel - GitHub](https://github.com/erebe/wstunnel)
- [WireGuard through WebSocket Tunnel](https://computerscot.github.io/wireguard-through-wstunnel.html)
- [Running WireGuard over TCP - eduVPN](https://www.eduvpn.org/running-wireguard-over-tcp-a-solution-for-udp-blocking-issues/)
- [SoftEther VPN Features](https://www.softether.org/1-features/4._Fast_Throughput_and_High_Ability)
