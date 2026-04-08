#!/bin/bash
# v6-health-monitor.sh — IPv6 出口ヘルスチェック & RA プレフィックス廃止/復旧
#
# r3 の VyOS task-scheduler で 5 秒間隔実行:
#   set system task-scheduler task v6-health interval 5
#   set system task-scheduler task v6-health executable path /config/scripts/v6-health-monitor.sh
#
# 動作:
#   各出口 (OPTAGE via r1, GCP via r2) に対して ping プローブを実行。
#   3 回連続失敗で障害判定 → 該当プレフィックスの RA を lifetime=0 に変更。
#   3 回連続成功で復旧判定 → RA を通常 lifetime に戻す。
#
# 判定タイムライン:
#   t=0s    障害発生
#   t=15s   3 回連続失敗 → RA lifetime=0 送出
#   t=16-20s クライアントが deprecated プレフィックスの使用を停止

STATE_DIR="/tmp/v6-health"
API_URL="https://192.168.11.1"
API_KEY="BwAI"
LOG_TAG="v6-health"

FAIL_THRESHOLD=3   # 連続失敗回数で障害判定
OK_THRESHOLD=3     # 連続成功回数で復旧判定

# プローブ先 (複数指定: いずれか 1 つに到達できれば OK)
PROBE_TARGETS="2001:4860:4860::8888 2606:4700:4700::1111"

log() { logger -t "$LOG_TAG" "$1"; }
mkdir -p "$STATE_DIR"

# --- プローブ関数 ---
# 引数: $1=出口名, $2=ソースアドレス
# ソースアドレスを指定することで、カーネルの src-based ルーティングにより
# OPTAGE ソース → wg0 → r1, GCP ソース → wg1 → r2 に振り分けられる。
# ※ GCP プレフィックス未設定時は GCP プローブをスキップ
probe_exit() {
    local exit_name="$1"
    local src_addr="$2"

    if [ -z "$src_addr" ]; then
        return 1  # ソースアドレスなし → スキップ
    fi

    for target in $PROBE_TARGETS; do
        if ping -6 -c 1 -W 2 -I "$src_addr" "$target" > /dev/null 2>&1; then
            return 0  # 1 つでも到達できれば OK
        fi
    done
    return 1  # 全滅
}

# --- 状態管理関数 ---
get_fail_count() {
    cat "$STATE_DIR/${1}_fail" 2>/dev/null || echo 0
}

get_ok_count() {
    cat "$STATE_DIR/${1}_ok" 2>/dev/null || echo 0
}

get_status() {
    cat "$STATE_DIR/${1}_status" 2>/dev/null || echo "up"
}

# --- RA 制御関数 ---
deprecate_prefix() {
    local prefix="$1"
    log "DEPRECATING prefix $prefix (RA lifetime=0)"
    # VLAN 30, 40 両方の RA プレフィックスを lifetime=0 に変更
    curl -sk --connect-timeout 5 -X POST "$API_URL/configure" \
        -H 'Content-Type: application/json' \
        -d "$(cat <<JSON
{
  "key": "$API_KEY",
  "commands": [
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "$prefix", "preferred-lifetime", "0"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "$prefix", "valid-lifetime", "0"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "$prefix", "preferred-lifetime", "0"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "$prefix", "valid-lifetime", "0"]}
  ]
}
JSON
)" > /dev/null 2>&1
}

restore_prefix() {
    local prefix="$1"
    log "RESTORING prefix $prefix (RA lifetime=default)"
    # lifetime 設定を削除してデフォルト (infinite) に戻す
    curl -sk --connect-timeout 5 -X POST "$API_URL/configure" \
        -H 'Content-Type: application/json' \
        -d "$(cat <<JSON
{
  "key": "$API_KEY",
  "commands": [
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "$prefix", "preferred-lifetime"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "$prefix", "valid-lifetime"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "$prefix", "preferred-lifetime"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "$prefix", "valid-lifetime"]}
  ]
}
JSON
)" > /dev/null 2>&1
}

# --- メインロジック ---
# 現在の RA プレフィックスを取得 (API: data.prefix.{prefix_name} の構造)
RA_JSON=$(curl -sk --connect-timeout 3 -X POST "$API_URL/retrieve" \
    -d "{\"key\":\"$API_KEY\",\"op\":\"showConfig\",\"path\":[\"service\",\"router-advert\",\"interface\",\"eth2.30\",\"prefix\"]}" \
    2>/dev/null)

OPTAGE_PREFIX=$(echo "$RA_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
prefixes = d.get('data', {}).get('prefix', {})
for k in prefixes:
    if k.startswith('2001:ce8:'):
        print(k)
        break
" 2>/dev/null)

GCP_PREFIX=$(echo "$RA_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
prefixes = d.get('data', {}).get('prefix', {})
for k in prefixes:
    if not k.startswith('2001:ce8:'):
        print(k)
        break
" 2>/dev/null)

# OPTAGE 出口チェック
if [ -n "$OPTAGE_PREFIX" ]; then
    # プレフィックスからルーターアドレスを取得 (::1)
    OPTAGE_SRC=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${OPTAGE_PREFIX}')
print(str(net.network_address) + '1')
" 2>/dev/null)

    if probe_exit "optage" "$OPTAGE_SRC"; then
        # 成功
        echo 0 > "$STATE_DIR/optage_fail"
        OK_COUNT=$(get_ok_count optage)
        OK_COUNT=$((OK_COUNT + 1))
        echo "$OK_COUNT" > "$STATE_DIR/optage_ok"

        if [ "$(get_status optage)" = "down" ] && [ "$OK_COUNT" -ge "$OK_THRESHOLD" ]; then
            log "OPTAGE exit RECOVERED ($OK_COUNT consecutive OK)"
            restore_prefix "$OPTAGE_PREFIX"
            echo "up" > "$STATE_DIR/optage_status"
        fi
    else
        # 失敗
        echo 0 > "$STATE_DIR/optage_ok"
        FAIL_COUNT=$(get_fail_count optage)
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$FAIL_COUNT" > "$STATE_DIR/optage_fail"

        if [ "$(get_status optage)" = "up" ] && [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ]; then
            log "OPTAGE exit FAILED ($FAIL_COUNT consecutive failures)"
            deprecate_prefix "$OPTAGE_PREFIX"
            echo "down" > "$STATE_DIR/optage_status"
        fi
    fi
fi

# GCP 出口チェック (プレフィックス未設定時はスキップ)
if [ -n "$GCP_PREFIX" ]; then
    GCP_SRC=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${GCP_PREFIX}')
print(str(net.network_address) + '1')
" 2>/dev/null)

    if probe_exit "gcp" "$GCP_SRC"; then
        echo 0 > "$STATE_DIR/gcp_fail"
        OK_COUNT=$(get_ok_count gcp)
        OK_COUNT=$((OK_COUNT + 1))
        echo "$OK_COUNT" > "$STATE_DIR/gcp_ok"

        if [ "$(get_status gcp)" = "down" ] && [ "$OK_COUNT" -ge "$OK_THRESHOLD" ]; then
            log "GCP exit RECOVERED ($OK_COUNT consecutive OK)"
            restore_prefix "$GCP_PREFIX"
            echo "up" > "$STATE_DIR/gcp_status"
        fi
    else
        echo 0 > "$STATE_DIR/gcp_ok"
        FAIL_COUNT=$(get_fail_count gcp)
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$FAIL_COUNT" > "$STATE_DIR/gcp_fail"

        if [ "$(get_status gcp)" = "up" ] && [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ]; then
            log "GCP exit FAILED ($FAIL_COUNT consecutive failures)"
            deprecate_prefix "$GCP_PREFIX"
            echo "down" > "$STATE_DIR/gcp_status"
        fi
    fi
fi
