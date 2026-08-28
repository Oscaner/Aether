# Aether 号池分组与套餐管理 — 运维手册

> 配套设计：docs/superpowers/specs/2026-08-27-group-plan-management-design.md
> 配套计划：docs/superpowers/plans/2026-08-27-group-plan-management.md
> 零代码改动，全部通过既有 admin API 完成。

## §1 初始置备

**一键执行**（幂等，重复运行复用已存在同名项）：
```bash
export AETHER_BASE="https://aether.example.com"
export MGMT_TOKEN="mgmt_xxx"   # admin:users + admin:billing，过 IP 白名单
bash scripts/aether/provision.sh
# 输出 4 分组 + 3 套餐的 id，追加到 .env（仅追加/更新 id，不覆盖已有变量）
```

### 手动置备（不使用脚本时参考）

所有请求带 `-H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json"`，下文省略。

**建 4 个分组**（Default 锁死用 specific 空列表，非 deny_all）：

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
# 执行后把返回的 id 记为 <DEFAULT_GROUP_ID>（供套餐 grant_user_groups 引用）
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

**建 3 个月卡套餐**（混合：daily_quota + membership_group）：

基础月卡（$0.5/天 → 基础组）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/billing/plans" -d '{
  "title": "基础月卡", "description": "基础档，每日额度 $0.5，动态授予基础组",
  "price_amount": 0, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 10, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":0.5,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$BASIC_GROUP_ID"'"]}
  ]
}'
# 执行后把返回的 id 记为 <BASIC_PLAN_ID>（后续调级/回收时引用）
```
标准月卡（$5/天 → 标准组）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/billing/plans" -d '{
  "title": "标准月卡", "description": "标准档，每日额度 $5，动态授予标准组",
  "price_amount": 0, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 20, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":5,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$STANDARD_GROUP_ID"'"]}
  ]
}'
# 执行后把返回的 id 记为 <STANDARD_PLAN_ID>
```
高级月卡（$20/天 → 高级组）：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/billing/plans" -d '{
  "title": "高级月卡", "description": "高级档，每日额度 $20，动态授予高级组",
  "price_amount": 0, "price_currency": "USD",
  "duration_unit": "month", "duration_value": 1, "enabled": true,
  "sort_order": 30, "max_active_per_user": 1, "purchase_limit_scope": "active_period",
  "entitlements": [
    {"type":"daily_quota","daily_quota_usd":20,"reset_timezone":"Asia/Shanghai","carry_over":false,"allow_wallet_overage":false},
    {"type":"membership_group","grant_user_groups":["'"$PREMIUM_GROUP_ID"'"]}
  ]
}'
# 执行后把返回的 id 记为 <PREMIUM_PLAN_ID>
```

### 验证
- `GET /api/admin/user-groups`：Default is_default=true 且三处均为 specific + 空列表
- `GET /api/admin/billing/plans`：3 个月卡各含 daily_quota(0.5/5/20) + membership_group(对应分组 id)

---

## §2 日常操作

### 分配套餐（新员工开通）
管理员后台 Users 页选中用户 → 分配对应月卡；或 API：
```bash
curl -sS -X POST "$AETHER_BASE/api/admin/users/<USER_ID>/billing/grant-plan" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d '{"plan_id": "<STANDARD_PLAN_ID>", "reason": "入职开通"}'
```
效果：系统动态加进对应分组 + 开通 daily_quota，立即可用。

### 调级（升/降档）
重新 grant 目标档位套餐即可；后端按 entitlement type 匹配，旧同类型 active 权益自动 replaced。
例：基础→标准：grant 标准月卡 plan_id，旧基础权益标记 replaced。

### 回收（离职/违规）
- 不续期 → 到期后自动从分组移出、回到 Default 锁死（被动重算，无需手动）。
- 立即封禁：管理员后台禁用账户（is_active=false），或手动移出分组。

### 临时限权（运维旋钮）
直接改分组权限（不改套餐）：
```bash
curl -sS -X PUT "$AETHER_BASE/api/admin/user-groups/<GROUP_ID>" \
  -H "Authorization: Bearer $MGMT_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"<名称>","allowed_providers_mode":"unrestricted","allowed_providers":null,
       "allowed_api_formats_mode":"unrestricted","allowed_api_formats":null,
       "allowed_models_mode":"specific","allowed_models":["gpt-4o-mini","claude-sonnet-4"],
       "rate_limit_mode":"system","rate_limit":null}'
```
立即对所有组内成员生效。用完改回 `allowed_models_mode: "unrestricted"`。

---

## §3 续期脚本部署

续期脚本：`scripts/aether/renew-plans.sh`

- 机制：每天 cron 遍历用户，对 active 且 `expires_at ≤ now+3天` 的套餐用同 `plan_id` 重新 grant；旧同类型权益后端自动 replaced，无双额度并存。
- 日期解析统一用 python3（跨 macOS/Linux，避免 date 偏移误判）。
- 依赖：curl / jq / python3

### 部署

**方式 A：docker-compose cron service（推荐，生产环境）**

cron service 已内置在 `docker-compose.yml` 和 `docker-compose.single-node.yml` 中，随主服务一起启动：

```bash
# 首次部署：先用 provision.sh 置备分组/套餐，生成 .env 中的分组/套餐 id
bash scripts/aether/provision.sh

# 启动主服务 + cron
docker compose up -d
# cron 容器自动每天 03:07 执行续期，日志输出到 docker logs aether-cron
docker logs -f aether-cron
```

cron service 构建自 `scripts/aether/Dockerfile`（alpine + bash/curl/jq/python3），通过 `env_file` 注入 `.env` 中的环境变量，依赖 app 启动后运行。

**方式 B：宿主机 crontab（无 docker 环境）**

```bash
# 注册 crontab（每天 03:07，绝对路径）
(crontab -l 2>/dev/null; echo "7 3 * * * $(pwd)/scripts/aether/renew-plans.sh $(pwd)/.env >> /var/log/aether-renew.log 2>&1") | crontab -
crontab -l | grep renew-plans
```

### 验证
```bash
bash -x scripts/aether/renew-plans.sh .env 2>&1 | head -30
# 首次运行预期：遍历用户、打印 renewed=0（无套餐进入 3 天窗口）；无报错。
# 真实续期发生在某用户套餐进入"现在+3天"窗口时（每日 cron 自动触发），无需人工干预。
tail -5 /var/log/aether-renew.log  # 检查日志
```

### 注意
- `.env` 含 `MGMT_TOKEN`，已在 `.gitignore` 中忽略。
- docker-compose 用户：cron 由容器自动调度，无需手动注册 crontab。若需修改调度时间，编辑 `scripts/aether/crontab` 后重建：`docker compose up -d --build cron`。
- 宿主机用户：cron 用绝对路径；若 `MGMT_TOKEN` 过期或 IP 白名单变更，需更新 `.env`。

---

## §4 监控排障

### 查看用量
- 员工前端自见当日/月度用量（usage 页）。
- 管理员看统计页 + 分组用量 Top 排名。

### "用不了"排查树
1. **是否还在 Default 组、未分配任何套餐？** → 分配对应月卡。
2. **套餐是否已过期？** → `GET /api/admin/users/{id}/billing/entitlements` 检查 active/expires_at；过期则不续期已回收，需重新分配。
3. **当日额度是否耗尽？** → daily_quota 用尽即硬切断（429/403）；次日重置，或管理员临时调高档位套餐。
4. **是否 Default 锁死仍在生效？** → 确认已分配正式套餐（membership_group 已加组）；OR 逻辑下正式组 unrestricted 应覆盖 Default。

### 排障命令
```bash
# 查用户套餐
curl -sS "$AETHER_BASE/api/admin/users/<USER_ID>/billing/entitlements" \
  -H "Authorization: Bearer $MGMT_TOKEN" | jq '.items[] | {plan_id, status, active, expires_at}'

# 查用户分组
curl -sS "$AETHER_BASE/api/admin/users/<USER_ID>" \
  -H "Authorization: Bearer $MGMT_TOKEN" | jq '{groups: [.groups[]?.name]}'

# 查分组权限配置
curl -sS "$AETHER_BASE/api/admin/user-groups" \
  -H "Authorization: Bearer $MGMT_TOKEN" | jq '.items[] | {name, allowed_models_mode, allowed_models}'
```

---

## §5 应急流程

### 临时提额
不修改套餐结构：直接 grant 更高档月卡（旧档 replaced），或短期改分组 `rate_limit/custom`。
用完降回原档。

### 违规封禁
管理员后台禁用账户（`is_active=false`）或手动移出所有正式分组 → 回 Default 锁死。
记录 reason 到 grant/操作审计。

### 离职回收
禁用账户 + 停止续期；到期后自动回收分组与额度，无需手动删行。

### 续期脚本故障
- 日志报错：检查 `MGMT_TOKEN` 是否过期 / IP 白名单是否变化 / cron 路径是否为绝对路径。
- 暂停续期：`crontab -l` 注释该行；手动对快到期用户 `grant` 同 `plan_id` 兜底。
