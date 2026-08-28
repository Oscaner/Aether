#!/usr/bin/env bash
# Aether 套餐自动续期：每天运行，对"到期前 3 天内"的 active 套餐用同 plan_id 重新 grant。
# 设计要点：单层循环、变量作用域在父 shell，避免管道子 shell 丢变量；旧同类型权益后端自动 replaced。
set -uo pipefail

# 环境变量注入：优先从容器环境读取（docker-compose env_file），否则 source .env
if [ -z "${AETHER_BASE:-}" ] || [ -z "${MGMT_TOKEN:-}" ]; then
  ENV_FILE="${1:-.env}"
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
FAILED=0

# temp 文件清理：脚本退出时自动删除
WORK=$(mktemp)
cleanup() { rm -f "$WORK"; }
trap cleanup EXIT

# 解析 RFC3339 时间串为 epoch；统一按 UTC，跨平台用 python3（避免 +08:00 偏移误判）
to_epoch() {
  local s="$1"
  python3 - "$s" <<'PY' 2>/dev/null || echo "$NOW_EPOCH"
import sys, datetime
s = sys.argv[1].replace('Z', '+00:00')
if '.' in s:
    dot = s.index('.')
    end = dot + 1
    while end < len(s) and s[end].isdigit():
        end += 1
    s = s[:dot] + s[end:]
print(int(datetime.datetime.fromisoformat(s).timestamp()))
PY
}

# 单趟 API 调用，返回 HTTP 状态码和响应体
api_status() {
  local url="$1"
  curl -sS -w "\n%{http_code}" "$url" -H "Authorization: Bearer $MGMT_TOKEN" 2>/dev/null
}

# ---- 阶段 1：收集需要续期的 (uid, plan_id, expires_at) ----
skip=0
while :; do
  resp=$(curl -sS -w "\n%{http_code}" "$AETHER_BASE/api/admin/users?limit=1000&skip=$skip" \
    -H "Authorization: Bearer $MGMT_TOKEN" 2>/dev/null)
  http_code=$(echo "$resp" | tail -1)
  page=$(echo "$resp" | sed '$d')

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "错误: GET /api/admin/users → HTTP $http_code" >&2
    echo "响应: ${page:0:200}" >&2
    exit 1
  fi
  if ! echo "$page" | jq empty 2>/dev/null; then
    echo "错误: GET /api/admin/users 返回非 JSON (HTTP $http_code)" >&2
    echo "响应前 200 字符: ${page:0:200}" >&2
    exit 1
  fi

  echo "$page" | jq -r '.items[]? | .id' | while read -r uid; do
    ents=$(curl -sS -w "\n%{http_code}" \
      "$AETHER_BASE/api/admin/users/$uid/billing/entitlements" \
      -H "Authorization: Bearer $MGMT_TOKEN" 2>/dev/null)
    ecode=$(echo "$ents" | tail -1)
    ebody=$(echo "$ents" | sed '$d')
    if [ "$ecode" -lt 200 ] || [ "$ecode" -ge 300 ]; then
      echo "跳过 user=$uid: entitlements HTTP $ecode" >&2
      continue
    fi
    echo "$ebody" | jq -r --arg uid "$uid" '
      .items[]?
      | select(.active == true and (.expires_at != null))
      | "\($uid)\t\(.plan_id)\t\(.expires_at)"' \
      >> "$WORK"
  done

  has_more=$(echo "$page" | jq -r '.has_more')
  [ "$has_more" = "true" ] || break
  skip=$(( skip + 1000 ))
done

# ---- 阶段 2：逐条续期 ----
while IFS=$'\t' read -r uid pid exp; do
  [ -n "$uid" ] || continue
  exp_epoch=$(to_epoch "$exp")
  if [ "$exp_epoch" -le "$WINDOW_EPOCH" ]; then
    grant_resp=$(curl -sS -w "\n%{http_code}" \
      -X POST "$AETHER_BASE/api/admin/users/$uid/billing/grant-plan" \
      -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
      -d "{\"plan_id\":\"$pid\",\"reason\":\"auto-renewal\"}" 2>/dev/null)
    gcode=$(echo "$grant_resp" | tail -1)
    gbody=$(echo "$grant_resp" | sed '$d')
    if [ "$gcode" -ge 200 ] && [ "$gcode" -lt 300 ]; then
      echo "renewed user=$uid plan=$pid"
      RENEWED=$((RENEWED + 1))
    else
      echo "失败 user=$uid plan=$pid → HTTP $gcode: ${gbody:0:200}" >&2
      FAILED=$((FAILED + 1))
    fi
  fi
done < "$WORK"

echo "renewal pass done: renewed=$RENEWED failed=$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
