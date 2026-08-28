#!/usr/bin/env bash
# Aether 号池分组与套餐管理 — 初始置备脚本
# 一键创建 4 个常驻分组 + 3 个月卡套餐 + 设系统默认组，并把置备产生的 id 追加到 .env。
# 用法：
#   1) 确保 .env 中已设置 AETHER_BASE 与 MGMT_TOKEN；
#   2) bash scripts/aether/provision.sh
# 约束：零代码改动，仅调用既有 admin API；重复运行会幂等跳过已存在的同名项。
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

# 从 .env 加载 AETHER_BASE / MGMT_TOKEN（用户在运行 provision.sh 前须已在 .env 中配置）
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

AETHER_BASE="${AETHER_BASE:-}"
MGMT_TOKEN="${MGMT_TOKEN:-}"

if [ -z "$AETHER_BASE" ] || [ -z "$MGMT_TOKEN" ]; then
  echo "错误：请先在 .env 中设置 AETHER_BASE 与 MGMT_TOKEN" >&2
  exit 1
fi

AUTH=(-H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json")

# 若 .env 中已有之前置备的 id，加载它们（幂等复用，不重复创建）
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null || true

# 清理无效 id（上一次失败运行可能写入了 "null" 字符串）
for _var in DEFAULT_GROUP_ID BASIC_GROUP_ID STANDARD_GROUP_ID PREMIUM_GROUP_ID \
            BASIC_PLAN_ID STANDARD_PLAN_ID PREMIUM_PLAN_ID; do
  eval "_val=\${$_var:-}"
  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
    eval "$_var=\"\""
  fi
done

# ---- 辅助函数 ----
upsert_env() {
  # 向 .env 追加或更新 KEY=VALUE（不触碰已有无关变量）
  local key="$1" val="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${key}=\"${val}\"|" "$file" 2>/dev/null \
      || sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
  else
    echo "${key}=\"${val}\"" >> "$file"
  fi
}

api_call() {
  # 发起 API 调用，检查 HTTP 状态码和 JSON 有效性，失败时打印诊断并 exit 1
  local method="$1" url="$2" body="${3:-}"
  local http_code resp
  if [ -n "$body" ]; then
    resp=$(curl -sS -w "\n%{http_code}" -X "$method" "$url" "${AUTH[@]}" -d "$body")
  else
    resp=$(curl -sS -w "\n%{http_code}" -X "$method" "$url" "${AUTH[@]}")
  fi
  http_code=$(echo "$resp" | tail -1)
  resp=$(echo "$resp" | sed '$d')
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "错误: $method $url → HTTP $http_code" >&2
    echo "响应: $resp" >&2
    exit 1
  fi
  if ! echo "$resp" | jq empty 2>/dev/null; then
    echo "错误: $method $url 返回非 JSON (HTTP $http_code)" >&2
    echo "响应前 200 字符: ${resp:0:200}" >&2
    exit 1
  fi
  echo "$resp"
}

create_group() {
  local name="$1" desc="$2"
  local existing resp
  resp=$(api_call GET "$AETHER_BASE/api/admin/user-groups")
  existing=$(echo "$resp" | jq -r --arg n "$name" '.items[]? | select(.name==$n) | .id' | head -1)
  if [ -n "$existing" ]; then
    echo "复用已存在分组: $name ($existing)" >&2
    echo "$existing"
    return
  fi
  resp=$(api_call POST "$AETHER_BASE/api/admin/user-groups" "$3")
  echo "$resp" | jq -r '.id'
}

create_plan() {
  local title="$1"
  local existing resp
  resp=$(api_call GET "$AETHER_BASE/api/admin/billing/plans")
  existing=$(echo "$resp" | jq -r --arg t "$title" '.items[]? | select(.title==$t) | .id' | head -1)
  if [ -n "$existing" ]; then
    echo "复用已存在套餐: $title ($existing)" >&2
    echo "$existing"
    return
  fi
  resp=$(api_call POST "$AETHER_BASE/api/admin/billing/plans" "$2")
  echo "$resp" | jq -r '.id'
}

# ---- Task 1: 4 个分组 ----
DEFAULT_GROUP_ID="${DEFAULT_GROUP_ID:-$(create_group "Default" "新注册员工默认落入此组，specific 空列表锁死所有模型/供应商/格式" '{
  "name": "Default",
  "description": "新注册员工默认落入此组，specific 空列表锁死所有模型/供应商/格式",
  "allowed_providers_mode": "specific", "allowed_providers": [],
  "allowed_api_formats_mode": "specific", "allowed_api_formats": [],
  "allowed_models_mode": "specific", "allowed_models": [],
  "rate_limit_mode": "system", "rate_limit": null
}')}"

BASIC_GROUP_ID="${BASIC_GROUP_ID:-$(create_group "Basic" "基础档 0.5/天" '{
  "name": "Basic", "description": "基础档 $0.5/天，unrestricted 权限（模型范围与企业一致），额度由套餐控制",
  "allowed_providers_mode": "unrestricted", "allowed_providers": null,
  "allowed_api_formats_mode": "unrestricted", "allowed_api_formats": null,
  "allowed_models_mode": "unrestricted", "allowed_models": null,
  "rate_limit_mode": "system", "rate_limit": null
}')}"

STANDARD_GROUP_ID="${STANDARD_GROUP_ID:-$(create_group "Standard" "标准档 5/天" '{
  "name": "Standard", "description": "标准档 $5/天，unrestricted 权限",
  "allowed_providers_mode": "unrestricted", "allowed_providers": null,
  "allowed_api_formats_mode": "unrestricted", "allowed_api_formats": null,
  "allowed_models_mode": "unrestricted", "allowed_models": null,
  "rate_limit_mode": "system", "rate_limit": null
}')}"

PREMIUM_GROUP_ID="${PREMIUM_GROUP_ID:-$(create_group "Premium" "高级档 20/天" '{
  "name": "Premium", "description": "高级档 $20/天，unrestricted 权限",
  "allowed_providers_mode": "unrestricted", "allowed_providers": null,
  "allowed_api_formats_mode": "unrestricted", "allowed_api_formats": null,
  "allowed_models_mode": "unrestricted", "allowed_models": null,
  "rate_limit_mode": "system", "rate_limit": null
}')}"

# ---- 设系统默认组（SSO 自动入组键）----
http_code=$(curl -sS -o /tmp/_aether_default_resp.json -w "%{http_code}" \
  -X PUT "$AETHER_BASE/api/admin/user-groups/default" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"group_id\":\"$DEFAULT_GROUP_ID\"}")
if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
  echo "错误: PUT /api/admin/user-groups/default → HTTP $http_code" >&2
  cat /tmp/_aether_default_resp.json >&2
  exit 1
fi
echo "已设 Default 为系统默认组: $DEFAULT_GROUP_ID"

# ---- Task 2: 3 个月卡套餐 ----
BASIC_PLAN_ID="${BASIC_PLAN_ID:-$(create_plan "基础月卡" '{
  "title": "基础月卡", "description": "基础档，每日额度 $0.5，动态授予基础组",
  "price_amount": 0.01, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 10, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":0.5,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$BASIC_GROUP_ID"'"]}
  ]
}')}"

STANDARD_PLAN_ID="${STANDARD_PLAN_ID:-$(create_plan "标准月卡" '{
  "title": "标准月卡", "description": "标准档，每日额度 $5，动态授予标准组",
  "price_amount": 0.01, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 20, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":5,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$STANDARD_GROUP_ID"'"]}
  ]
}')}"

PREMIUM_PLAN_ID="${PREMIUM_PLAN_ID:-$(create_plan "高级月卡" '{
  "title": "高级月卡", "description": "高级档，每日额度 $20，动态授予高级组",
  "price_amount": 0.01, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 30, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":20,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$PREMIUM_GROUP_ID"'"]}
  ]
}')}"

# ---- 追加置备 id 到 .env（仅追加/更新 id，不覆盖用户已有变量） ----
# 校验所有 id 非空，否则中断不写入（避免 null 污染 .env）
for _check in DEFAULT_GROUP_ID BASIC_GROUP_ID STANDARD_GROUP_ID PREMIUM_GROUP_ID \
              BASIC_PLAN_ID STANDARD_PLAN_ID PREMIUM_PLAN_ID; do
  eval "_val=\${$_check:-}"
  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
    echo "错误: $_check 为空或 null，API 创建可能失败，中止写入 .env" >&2
    exit 1
  fi
done

for kv in \
  "DEFAULT_GROUP_ID=$DEFAULT_GROUP_ID" \
  "BASIC_GROUP_ID=$BASIC_GROUP_ID" \
  "STANDARD_GROUP_ID=$STANDARD_GROUP_ID" \
  "PREMIUM_GROUP_ID=$PREMIUM_GROUP_ID" \
  "BASIC_PLAN_ID=$BASIC_PLAN_ID" \
  "STANDARD_PLAN_ID=$STANDARD_PLAN_ID" \
  "PREMIUM_PLAN_ID=$PREMIUM_PLAN_ID"; do
  key="${kv%%=*}" val="${kv#*=}"
  upsert_env "$key" "$val" "$ENV_FILE"
done

echo "置备完成，id 已追加到 $ENV_FILE"
echo "分组: Default=$DEFAULT_GROUP_ID Basic=$BASIC_GROUP_ID Standard=$STANDARD_GROUP_ID Premium=$PREMIUM_GROUP_ID"
echo "套餐: 基础=$BASIC_PLAN_ID 标准=$STANDARD_PLAN_ID 高级=$PREMIUM_PLAN_ID"
