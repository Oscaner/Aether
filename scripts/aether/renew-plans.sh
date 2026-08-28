#!/usr/bin/env bash
# Aether 套餐自动续期：每天运行，对"到期前 3 天内"的 active 套餐用同 plan_id 重新 grant。
# 设计要点：单层循环、变量作用域在父 shell，避免管道子 shell 丢变量；旧同类型权益后端自动 replaced。
set -uo pipefail

# 环境变量注入：优先从容器环境读取（docker-compose env_file），否则 source 本地 .env 文件
if [ -z "${AETHER_BASE:-}" ] || [ -z "${MGMT_TOKEN:-}" ]; then
  ENV_FILE="${1:-.env.aether}"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    echo "错误：AETHER_BASE 与 MGMT_TOKEN 未设置，且 $ENV_FILE 不存在" >&2
    exit 1
  fi
fi

RENEW_WINDOW_DAYS=3
NOW_EPOCH=$(date +%s)
WINDOW_EPOCH=$(( NOW_EPOCH + RENEW_WINDOW_DAYS * 86400 ))
RENEWED=0

# 解析 RFC3339 时间串为 epoch；统一按 UTC，跨平台用 python3（避免 +08:00 偏移误判）
to_epoch() {
  local s="$1"
  # 归一化 RFC3339（支持 Z / +08:00 / 含毫秒），统一解析为 UTC epoch 秒
  python3 - "$s" <<'PY' 2>/dev/null || echo "$NOW_EPOCH"
import sys, datetime
s = sys.argv[1].replace('Z', '+00:00')
if '.' in s:  # 去除毫秒/微秒（旧版 fromisoformat 不支持小数秒）
    dot = s.index('.')
    end = dot + 1
    while end < len(s) and s[end].isdigit():
        end += 1
    s = s[:dot] + s[end:]
print(int(datetime.datetime.fromisoformat(s).timestamp()))
PY
}

# 单趟收集 (uid, plan_id, expires_at) 三元组到临时文件，避免嵌套管道丢作用域
WORK=$(mktemp)
skip=0
while :; do
  page=$(curl -sS "$AETHER_BASE/api/admin/users?limit=1000&skip=$skip" \
    -H "Authorization: Bearer $MGMT_TOKEN") || { echo "fetch users page failed" >&2; exit 1; }
  [ -n "$page" ] || { echo "empty users page" >&2; exit 1; }
  echo "$page" | jq -r '.items[]? | .id' | while read -r uid; do
    ents=$(curl -sS "$AETHER_BASE/api/admin/users/$uid/billing/entitlements" \
      -H "Authorization: Bearer $MGMT_TOKEN") || { echo "fetch entitlements failed for $uid" >&2; continue; }
    [ -n "$ents" ] || { echo "empty entitlements for $uid" >&2; continue; }
    echo "$ents" | jq -r '
      .items[]?
      | select(.active == true and (.expires_at != null))
      | "\($uid)\t\(.plan_id)\t\(.expires_at)"' \
      >> "$WORK"
  done
  # 分页：依赖 GET /api/admin/users 的 has_more 标志，每页 limit=1000，skip 自增直到 has_more=false
  has_more=$(echo "$page" | jq -r '.has_more')
  [ "$has_more" = "true" ] || break
  skip=$(( skip + 1000 ))
done

# 在父 shell 单层循环处理续期（uid/pid/exp 均在作用域内）
while IFS=$'\t' read -r uid pid exp; do
  [ -n "$uid" ] || continue
  exp_epoch=$(to_epoch "$exp")
  if [ "$exp_epoch" -le "$WINDOW_EPOCH" ]; then
    curl -sS -X POST "$AETHER_BASE/api/admin/users/$uid/billing/grant-plan" \
      -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
      -d "{\"plan_id\":\"$pid\",\"reason\":\"auto-renewal\"}" >/dev/null
    echo "renewed user=$uid plan=$pid"
    RENEWED=$((RENEWED + 1))
  fi
done < "$WORK"
rm -f "$WORK"
echo "renewal pass done, renewed=$RENEWED"
