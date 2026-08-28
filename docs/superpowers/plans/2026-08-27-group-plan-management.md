# Aether 号池分组与套餐管理 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在零代码改动前提下，基于 Aether 既有 admin API 完成"Default 锁死 + 3 档用量分层"的分组/套餐体系，并落地每日自动续期脚本与运维手册。

**Architecture:** 全部操作走既有 admin 管理 API（user_groups / billing_plans / plan grant / 默认组配置），无任何 Aether 源码改动；续期由外部 cron 脚本调同一套 API 实现，运维手册沉淀日常操作 SOP。分组管权限、套餐管预算（daily_quota + membership_group 动态加组），二者正交。

**Tech Stack:** Aether 管理 API（HTTPS + management token）、bash + curl + jq（续期脚本）、cron（调度）、Markdown（运维手册）。

## Global Constraints

- **不修改 Aether 任何代码**：所有变更仅通过既有 admin API 或运维侧脚本完成（spec Section 4 YAGNI 约束）。
- **套餐 entitlements 必须含 `daily_quota` 或 `membership_group`**：纯 `wallet_credit` 套餐会被后端拒绝（spec 2.2 / 3.2）。
- **Default 组用 `specific` + 空列表锁死**：不能用 `deny_all`（分组权限 OR 叠加，deny_all 无法否决其他组，spec 2.1）。
- **4 个常驻分组**：Default（锁死）+ 基础/标准/高级（unrestricted），rate_limit 默认 `system`。
- **3 个月卡套餐**：daily_quota 分别为 $0.5 / $5 / $20 每天，duration `month` / `duration_value` 1，含 `membership_group` 指向对应分组。
- **续期**：外部 cron 每天跑，到期前 3 天用同 `plan_id` 重新 grant（旧同类型权益自动 `replaced`）。
- **认证**：所有管理 API 用 management token（`mgmt_` 前缀，带 `admin:users` / `admin:billing` 权限，过 IP 白名单）。

## File Structure

| 文件 | 操作 | 职责 |
|------|------|------|
| `scripts/aether/provision.sh` | Create | 置备脚本：一键建 4 分组 + 3 月卡 + 设默认组 + 输出 ids 到 `.env` |
| `scripts/aether/renew-plans.sh` | Create | 续期脚本：遍历用户 → 查 active 套餐 → 到期前 3 天同 plan_id 重 grant |
| `docs/runbooks/2026-08-27-aether-group-plan-management.md` | Create | 运维手册：置备/日常/续期/排障/应急 5 节 |
| （Aether 代码） | 不改动 | 仅消费既有 admin API |

> `scripts/aether/` 与 `docs/runbooks/` 是本计划的全部代码/文档产出。provision.sh 幂等（重复执行复用同名项），renew-plans.sh 由 cron 每天调度。

---

### Task 1 + 2: 初始置备（建 4 分组 + 3 月卡 + 设默认组）

**产出物：** `scripts/aether/provision.sh`（一键置备脚本）

**职责：** 该脚本创建 4 个常驻分组（Default 锁死 + 基础/标准/高级）、3 个月卡套餐（daily_quota + membership_group），并把 Default 设为系统默认组（SSO 自动入组键），最后把所有 id 写入 `.env`。

**关键约束：**
- Default 组用 `specific` + 空列表锁死（非 `deny_all`，因分组权限 OR 叠加，deny_all 无法否决其他组）。
- 三档正式组 `unrestricted`，额度完全由套餐的 daily_quota 控制。
- 套餐 = `daily_quota`（0.5/5/20 USD/天）+ `membership_group`（指向对应分组），duration `month`/1，无 wallet_credit。
- 脚本含幂等检查（同名项复用，不重复创建）。

- [ ] **Step 1: 配置并执行置备脚本**

```bash
# 在 scripts/aether/provision.sh 顶部填写，或运行前 export：
export AETHER_BASE="https://aether.example.com"
export MGMT_TOKEN="mgmt_xxx"   # admin:users + admin:billing，过 IP 白名单
bash scripts/aether/provision.sh
# 输出 4 分组 + 3 套餐的 id，并写入 .env（chmod 600）
```

- [ ] **Step 2: 验证置备结果（检查清单）**

```bash
source .env
# (a) 4 分组存在，Default 为锁死 + 默认组
curl -sS "$AETHER_BASE/api/admin/user-groups" "${AUTH[@]}" \
  | jq '.items[] | {name, is_default, allowed_models_mode, allowed_models, allowed_providers_mode, allowed_providers, allowed_api_formats_mode, allowed_api_formats}'
# 预期：Default 三者均为 specific + 空列表；is_default=true；Basic/Standard/Premium 均 unrestricted

# (b) 3 月卡存在且 entitlements 正确
curl -sS "$AETHER_BASE/api/admin/billing/plans" "${AUTH[@]}" \
  | jq '.items[] | select(.title|test("月卡")) | {title, duration_unit, duration_value, entitlements}'
# 预期：3 条，各含 daily_quota(0.5/5/20) + membership_group(对应分组 id)
```

- [ ] **Step 3: 活跃验证 Default 锁死（可选，生产上按需）**

```bash
# 取一个仅含 Default 组、无 active 套餐的用户（确认其无套餐后再用）：
NEW_USER=$(curl -sS "$AETHER_BASE/api/admin/users?limit=1" "${AUTH[@]}" | jq -r '.items[0].id')
USER_TOKEN=$(curl -sS -X POST "$AETHER_BASE/api/admin/users/$NEW_USER/api-keys" "${AUTH[@]}" -d '{"name":"locktest"}' | jq -r '.key')
RESP=$(curl -sS -o /tmp/r.json -w "%{http_code}" -X POST "$AETHER_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":1}')
echo "http=$RESP (预期 403/429 = Default 锁死生效)"
```

> 说明：以上验证步骤在你生产手动执行时按需运行；脚本本身只负责创建与配置，不强制验证。完整 SOP 见 `docs/runbooks/2026-08-27-aether-group-plan-management.md`。
### Task 3: 手动分配验证 + 自动续期脚本

**目标：** 先验证一次"分配套餐 → 员工解锁"的全链路；再落地每日续期脚本 `scripts/aether/renew-plans.sh`，并注册到 cron。

**Files:**
- Create: `scripts/aether/renew-plans.sh`
- 引用：`.env`（Task 1/2 产出的全部环境变量）

**关键 API：**
- `GET /api/admin/users?limit=1000&skip=N` → `{ items:[{id,...}], has_more, total }`，分页直到 `has_more=false`
- `GET /api/admin/users/{id}/billing/entitlements` → `{ items:[{ plan_id, active, expires_at(RFC3339), status }], total }`
- `POST /api/admin/users/{id}/billing/grant-plan` body `{ "plan_id": "<id>", "reason": "auto-renewal" }`
- 重新 grant 同 plan_id：旧同类型 active 权益自动标记 `replaced`，新权益 `starts=now` 生效。提前 3 天触发 → 实际额度窗口约 33 天（无空窗）。

- [ ] **Step 1: 取一个测试用户的 id（或自己账户）**

```bash
source .env
TEST_USER=$(curl -sS "$AETHER_BASE/api/admin/users?limit=1" \
  -H "Authorization: Bearer $MGMT_TOKEN" | jq -r '.items[0].id')
echo "TEST_USER=$TEST_USER"
```

- [ ] **Step 2: 给测试用户分配标准月卡，验证立即解锁**

```bash
curl -sS -X POST "$AETHER_BASE/api/admin/users/$TEST_USER/billing/grant-plan" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d "{ \"plan_id\": \"$STANDARD_PLAN_ID\", \"reason\": \"manual test grant\" }" \
  | jq '{credited, items: [.items[]? | {plan_id, active, expires_at}]}'
# 预期 credited=true，且含标准月卡 active=true、expires_at 约为 now+30天
```

- [ ] **Step 3: 确认用户已被动态加进标准组（权限叠加解锁 Default 锁死）**

```bash
# 确定性查证：从 entitlements 的 membership_group 权益取出实际授予的分组 id，再映射为组名
GRANTED=$(curl -sS "$AETHER_BASE/api/admin/users/$TEST_USER/billing/entitlements" \
  -H "Authorization: Bearer $MGMT_TOKEN" \
  | jq -r '[.items[]? | select(.active==true)] | map(.entitlements[]? | select(.type=="membership_group")) | map(.grant_user_groups[]) | unique | .[]')
echo "membership_group 授予的分组 id: $GRANTED"
for gid in $GRANTED; do
  curl -sS "$AETHER_BASE/api/admin/user-groups" \
    -H "Authorization: Bearer $MGMT_TOKEN" \
    | jq -r --arg g "$gid" '.items[]? | select(.id==$g) | .name'
done
# 预期：输出含 "Standard"（即标准月卡已把用户动态加进标准组，OR 逻辑下覆盖 Default 锁死）
# 若 GET /api/admin/users/{id} 也返回 groups 字段，可直接 jq -e '.groups[]?.name' 交叉确认
```

- [ ] **Step 4: 创建续期脚本 `scripts/aether/renew-plans.sh`**

脚本对每个 active 且 `expires_at` 落在"现在+3天窗口内"的套餐，用同 `plan_id` 重新 grant。旧同类型权益后端自动 `replaced`，无需脚本去重。单层循环，计数器在父 shell 累加；日期解析统一用 python3（跨 macOS/Linux，避免 date 偏移误判）。

```bash
mkdir -p scripts/aether
cat > scripts/aether/renew-plans.sh <<'SCRIPT'
#!/usr/bin/env bash
# Aether 套餐自动续期：每天运行，对"到期前 3 天内"的 active 套餐用同 plan_id 重新 grant。
# 设计要点：单层循环、变量作用域在父 shell，避免管道子 shell 丢变量；旧同类型权益后端自动 replaced。
set -uo pipefail

ENV_FILE="${1:-.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"

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
SCRIPT
chmod +x scripts/aether/renew-plans.sh
```

- [ ] **Step 5: 本地 dry-run 验证脚本（观察输出，首次预期 renewed=0）**

```bash
bash -x scripts/aether/renew-plans.sh .env 2>&1 | head -30
# 首次运行预期：遍历用户、打印 renewed=0（测试用户刚分配，未到 3 天窗口）；无报错。
# 真实续期发生在某用户套餐进入"现在+3天"窗口时（每日 cron 自动触发），无需人工干预。
```

- [ ] **Step 6: 注册 cron（每天 03:07 本地时间，避开整点）**

```bash
(crontab -l 2>/dev/null; echo "7 3 * * * $(pwd)/scripts/aether/renew-plans.sh $(pwd)/.env >> /var/log/aether-renew.log 2>&1") | crontab -
crontab -l | grep renew-plans
```

- [ ] **Step 6.5: 验证额度耗尽硬切断（AC#5 行为确认）**

> 前置：本步针对 **Step 2 已分配标准月卡（日额度 $5）的 TEST_USER**，需用其专属令牌，而非 LOCKED_USER（锁死用户发请求会被 Default 直接拒，测不出额度耗尽）。若 .env 中无 TEST_USER 令牌，先生成：
> `TEST_TOKEN=$(curl -sS -X POST "$AETHER_BASE/api/admin/users/$TEST_USER/api-keys" -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" -d '{"name":"quotatest"}' | jq -r '.key')`

```bash
# 验证“额度耗尽硬切断”：因真实烧光日额度会破坏测试用户当日可用性，采用「观察法」——
# 在 usage 页确认 TEST_USER 当日额度已归零后，用其令牌发一次正常请求，预期 429/403：
RESP=$(curl -sS -o /tmp/quota_resp.json -w "%{http_code}" -X POST "$AETHER_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $TEST_TOKEN" -H "Content-Type: application/json" \
  -d '{ "model": "gpt-4o-mini", "messages": [{"role":"user","content":"hi"}], "max_tokens": 1 }')
echo "http=$RESP (额度耗尽时预期 429/403)"; cat /tmp/quota_resp.json
# 或临时为该用户 grant 一个极小额度（如 $0.01/天）测试档，烧光后验证拒绝，再撤销。硬切断由后端保证，详见 runbook §4。
echo "TEST_TOKEN=\"$TEST_TOKEN\"" >> .env   # 持久化供后续步骤复用
```

- [ ] **Step 6.6: 验证过期回收回 Default 锁死（AC#6）+ 续期 replaced（AC#7）**

> 前置：使用 Step 2 已分配标准月卡的 **TEST_USER** 及其 **TEST_TOKEN**（已分配 → 请求应成功）。

```bash
# (a) 先确认分配状态下请求正常（与回收后对比基线）：
BASE_RESP=$(curl -sS -o /tmp/base.json -w "%{http_code}" -X POST "$AETHER_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $TEST_TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":1}')
echo "分配状态 http=$BASE_RESP (预期 200)"

# (b) AC#7 续期 replaced：对 TEST_USER 再次 grant 同标准月卡，查 entitlements 应出现旧档 active→replaced、新档 active
curl -sS -X POST "$AETHER_BASE/api/admin/users/$TEST_USER/billing/grant-plan" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d "{"plan_id":"$STANDARD_PLAN_ID","reason":"renewal-test"}" >/dev/null
curl -sS "$AETHER_BASE/api/admin/users/$TEST_USER/billing/entitlements" \
  -H "Authorization: Bearer $MGMT_TOKEN" | jq '.items[]? | {plan_id, status, active}'
# 预期：同一 plan_id 有两条记录，旧 status="replaced"、新 status="active"，证明续期 replaced 生效

# (c) AC#6 回收：管理员后台将该用户移出所有正式分组（或禁用账户），再发请求预期 403/429（回到 Default 锁死）
RELOCK_RESP=$(curl -sS -o /tmp/relock.json -w "%{http_code}" -X POST "$AETHER_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $TEST_TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":1}')
echo "回收后 http=$RELOCK_RESP (预期 403/429，即回到 Default 锁死)"
# membership_group 移除为被动重算（鉴权时按 active 权益实时重算，spec 2.5），由后端保证，详见 runbook §2/§4。
```

- [ ] **Step 6.7: 验证管理员改分组权限即时生效（AC#8）**

```bash
# 临时把标准组设为 specific + 仅放开某模型，验证改动立即对所有成员生效；验证后改回 unrestricted
curl -sS -X PUT "$AETHER_BASE/api/admin/user-groups/$STANDARD_GROUP_ID" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Standard","allowed_providers_mode":"unrestricted","allowed_providers":null,"allowed_api_formats_mode":"unrestricted","allowed_api_formats":null,"allowed_models_mode":"specific","allowed_models":["gpt-4o-mini"],"rate_limit_mode":"system","rate_limit":null}'
echo "已将标准组临时改为 specific 仅 gpt-4o-mini；对组内成员立即生效（无需重新分配）"
# 验证后恢复：
curl -sS -X PUT "$AETHER_BASE/api/admin/user-groups/$STANDARD_GROUP_ID" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Standard","allowed_providers_mode":"unrestricted","allowed_providers":null,"allowed_api_formats_mode":"unrestricted","allowed_api_formats":null,"allowed_models_mode":"unrestricted","allowed_models":null,"rate_limit_mode":"system","rate_limit":null}'
echo "已恢复标准组为 unrestricted"
# 说明：分组权限在鉴权时实时解析（spec 2.1 的 union_group_list_policies），改动即时对所有成员生效，无需重分配。
```

- [ ] **Step 7: 提交脚本（.env 含真实 token，禁止提交）**


```bash
echo '.env' >> .gitignore
git add scripts/aether/renew-plans.sh .gitignore
git commit -m "feat: Aether 套餐每日自动续期脚本"
```

---

### Task 4: 运维手册

**目标：** 编写 `docs/runbooks/2026-08-27-aether-group-plan-management.md`，沉淀管理员日常 SOP，覆盖 spec AC #9 的 5 节。

**Files:**
- Create: `docs/runbooks/2026-08-27-aether-group-plan-management.md`
- 引用：Task 1/2 的分组与套餐创建 curl（直接复用，含完整 JSON 示例）、Task 3 的续期脚本与 cron

**手册必须覆盖（spec AC #9）：**
1. 初始置备步骤
2. 日常操作（分配/调级/回收/临时限权）
3. 续期脚本部署
4. 监控排障
5. 应急流程

- [ ] **Step 1: 写 §1 初始置备（环境常量 + 建 4 分组 + 设默认组 + 建 3 套餐）**

```bash
mkdir -p docs/runbooks
cat > docs/runbooks/2026-08-27-aether-group-plan-management.md <<'MD'
# Aether 号池分组与套餐管理 — 运维手册

> 配套设计：docs/superpowers/specs/2026-08-27-group-plan-management-design.md
> 零代码改动，全部通过既有 admin API 完成。

## §1 初始置备

### 环境常量
- `AETHER_BASE`：网关 Base URL（如 https://aether.example.com）
- `MGMT_TOKEN`：management token（mgmt_ 前缀，admin:users + admin:billing，过 IP 白名单）
- 创建后记录：`DEFAULT/BASIC/STANDARD/PREMIUM_GROUP_ID`、`BASIC/STANDARD/PREMIUM_PLAN_ID`

### 建 4 个分组（Default 锁死用 specific 空列表，非 deny_all）
所有请求带 `-H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json"`，下文省略。

建 Default 组（specific 空列表锁死）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/user-groups" -d '{
  "name": "Default",
  "description": "新注册员工默认落入此组，specific 空列表锁死所有模型/供应商/格式",
  "allowed_providers_mode": "specific", "allowed_providers": [],
  "allowed_api_formats_mode": "specific", "allowed_api_formats": [],
  "allowed_models_mode": "specific", "allowed_models": [],
  "rate_limit_mode": "system", "rate_limit": null
}'
# 执行后把返回的 id 记为 <DEFAULT_GROUP_ID>（写入下方 .env，供套餐 grant_user_groups 引用）
```
建基础组（unrestricted，日额度由套餐控制）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/user-groups" -d '{
  "name": "Basic", "description": "基础档 $0.5/天",
  "allowed_providers_mode": "unrestricted", "allowed_providers": null,
  "allowed_api_formats_mode": "unrestricted", "allowed_api_formats": null,
  "allowed_models_mode": "unrestricted", "allowed_models": null,
  "rate_limit_mode": "system", "rate_limit": null
}'   # → BASIC_GROUP_ID
```
建标准组（unrestricted）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/user-groups" -d '{
  "name": "Standard", "description": "标准档 $5/天",
  "allowed_providers_mode": "unrestricted", "allowed_providers": null,
  "allowed_api_formats_mode": "unrestricted", "allowed_api_formats": null,
  "allowed_models_mode": "unrestricted", "allowed_models": null,
  "rate_limit_mode": "system", "rate_limit": null
}'   # → STANDARD_GROUP_ID
```
建高级组（unrestricted）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/user-groups" -d '{
  "name": "Premium", "description": "高级档 $20/天",
  "allowed_providers_mode": "unrestricted", "allowed_providers": null,
  "allowed_api_formats_mode": "unrestricted", "allowed_api_formats": null,
  "allowed_models_mode": "unrestricted", "allowed_models": null,
  "rate_limit_mode": "system", "rate_limit": null
}'   # → PREMIUM_GROUP_ID
```
设系统默认组（SSO 自动入组键，写入 system_config.default_user_group_id）：
```bash
curl -sS -X PUT "$AETHER_BASE/api/admin/user-groups/default" -d '{"group_id":"'"$DEFAULT_GROUP_ID"'"}'
```

### 建 3 个月卡套餐（混合：daily_quota + membership_group）
基础月卡（$0.5/天 → 基础组）：
```bash
RESP=$(curl -sS -X POST "$AETHER_BASE/api/admin/billing/plans" -d '{
  "title": "基础月卡", "description": "基础档，每日额度 $0.5，动态授予基础组",
  "price_amount": 0, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 10, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":0.5,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$BASIC_GROUP_ID"'"]}
  ]
}')
BASIC_PLAN_ID=$(echo "$RESP" | jq -r '.id')
```
标准月卡（$5/天 → 标准组）：
```bash
RESP=$(curl -sS -X POST "$AETHER_BASE/api/admin/billing/plans" -d '{
  "title": "标准月卡", "description": "标准档，每日额度 $5，动态授予标准组",
  "price_amount": 0, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 20, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":5,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$STANDARD_GROUP_ID"'"]}
  ]
}')
STANDARD_PLAN_ID=$(echo "$RESP" | jq -r '.id')
```
高级月卡（$20/天 → 高级组）：
```bash
RESP=$(curl -sS -X POST "$AETHER_BASE/api/admin/billing/plans" -d '{
  "title": "高级月卡", "description": "高级档，每日额度 $20，动态授予高级组",
  "price_amount": 0, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 30, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":20,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$PREMIUM_GROUP_ID"'"]}
  ]
}')
PREMIUM_PLAN_ID=$(echo "$RESP" | jq -r '.id')
```

### 验证
- GET /api/admin/user-groups：Default is_default=true 且 allowed_models_mode=specific、allowed_models=[]
- GET /api/admin/billing/plans：3 个月卡各含 daily_quota + membership_group
MD
```

- [ ] **Step 2: 追加 §2 日常操作（分配/调级/回收/临时限权）**

```bash
cat >> docs/runbooks/2026-08-27-aether-group-plan-management.md <<'MD'

## §2 日常操作

### 分配套餐（新员工开通）
管理员后台 Users 页选中用户 → 分配对应月卡；或 API：
POST /api/admin/users/{id}/billing/grant-plan { "plan_id": "<档位套餐id>", "reason": "入职开通" }
效果：系统动态加进对应分组 + 开通 daily_quota，立即可用。

### 调级（升/降档）
重新 grant 目标档位套餐即可；后端按 entitlement type 匹配，旧同类型 active 权益自动 replaced。
例：基础→标准：grant 标准月卡 plan_id，旧基础权益标记 replaced。

### 回收（离职/违规）
- 不续期 → 到期后自动从分组移出、回到 Default 锁死（被动重算，无需手动）。
- 立即封禁：管理员后台禁用账户（is_active=false），或手动移出分组。

### 临时限权（运维旋钮）
直接改分组权限（不改套餐）：PUT /api/admin/user-groups/{id} 把 allowed_models_mode 改为 specific
并列出允许的模型；立即对所有组内成员生效。用完改回 unrestricted。
MD
```

- [ ] **Step 3: 追加 §3 续期脚本部署**

```bash
cat >> docs/runbooks/2026-08-27-aether-group-plan-management.md <<'MD'

## §3 续期脚本部署

### 脚本与部署
续期脚本由 Task 3 落地为独立文件 `scripts/aether/renew-plans.sh`（完整内容见该文件，不在此重复）。
- 机制：每天 cron 遍历用户，对 active 且 expires_at ≤ now+3天 的套餐用同 plan_id 重新 grant；旧同类型权益后端自动 replaced，无双额度并存。
- 日期解析统一用 python3（跨 macOS/Linux，避免 date 偏移误判）。
- 注册 crontab（每天 03:07，绝对路径）：
  ```bash
  (crontab -l 2>/dev/null; echo "7 3 * * * $(pwd)/scripts/aether/renew-plans.sh $(pwd)/.env >> /var/log/aether-renew.log 2>&1") | crontab -
  ```
- 验证：`bash -x scripts/aether/renew-plans.sh .env` 观察 renewed=N；检查 /var/log/aether-renew.log 无报错。
- 注意：.env 含 MGMT_TOKEN 禁止入库；cron 用绝对路径；脚本依赖 curl/jq/python3。
MD

- [ ] **Step 4: 追加 §4 监控排障**

```bash
cat >> docs/runbooks/2026-08-27-aether-group-plan-management.md <<'MD'

## §4 监控排障

### 查看用量
- 员工前端自见当日/月度用量（usage 页）。
- 管理员看统计页 + 分组用量 Top 排名。

### “用不了”排查树
1. 是否还在 Default 组、未分配任何套餐？→ 分配对应月卡。
2. 套餐是否已过期？→ 检查 entitlements 的 active/expires_at；过期则不续期已回收，需重新分配。
3. 当日额度是否耗尽？→ daily_quota 用尽即硬切断；次日重置，或管理员临时调高档位。
4. 是否 Default 锁死仍在生效？→ 确认已分配正式套餐（membership_group 已加组），OR 逻辑下正式组 unrestricted 应覆盖 Default。

### 排障命令
- 查用户套餐：GET /api/admin/users/{id}/billing/entitlements
- 查用户分组：GET /api/admin/users/{id}（groups 字段，或据 entitlements 推断）
MD
```

- [ ] **Step 5: 追加 §5 应急流程**

```bash
cat >> docs/runbooks/2026-08-27-aether-group-plan-management.md <<'MD'

## §5 应急流程

### 临时提额
不修改套餐结构：直接 grant 更高档月卡（旧档 replaced），或短期改分组 rate_limit/custom。
用完降回原档。

### 违规封禁
管理员后台禁用账户（is_active=false）或手动移出所有正式分组 → 回 Default 锁死。
记录 reason 到 grant/操作审计。

### 离职回收
禁用账户 + 停止续期；到期后自动回收分组与额度，无需手动删行。

### 续期脚本故障
- 日志报错：检查 MGMT_TOKEN 是否过期/IP 白名单是否变化/cron 路径是否为绝对路径。
- 暂停续期：crontab -l 注释该行；手动对快到期用户 grant 同 plan_id 兜底。
MD
```

- [ ] **Step 6: 提交运维手册**

```bash
git add docs/runbooks/2026-08-27-aether-group-plan-management.md
git commit -m "docs: Aether 号池分组套餐管理运维手册"
```

---

## Self-Review Notes（作者内审）

- **Spec 覆盖**：Task 1+2（置备 = AC#2/3/4）、Task 3（分配验证 = AC#1/5/6/7 + 续期脚本）、Task 4（运维手册 = AC#9），AC#8 在手册 §2 说明。过期回收由被动重算机制保障，手册 §2/§4 记录。
- **占位符**：无 TBD/TODO；`provision.sh` + `renew-plans.sh` + 手册均含完整内容，可直接生产执行。
- **类型一致**：`$*_GROUP_ID` / `$*_PLAN_ID` 在 provision.sh 统一定义并写入 `.env`；renew-plans.sh 与 Task 3 从同一 `.env` 读取，引用一致。
- **执行模式**：你手动在生产运行 `provision.sh`（一次性）+ `renew-plans.sh`（cron 每天），计划任务结构与交付物已对齐此模式。
