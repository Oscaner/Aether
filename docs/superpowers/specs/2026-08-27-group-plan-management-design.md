# Aether 号池分组与套餐管理设计

- **Version**: 1.0
- **Status**: Approved
- **Author**: Oscaner Miao
- **Date**: 2026-08-27
- **Scope**: 企业内部自托管 Aether 的分组（权限容器）与套餐（预算控制）管理方案
- **Constraint**: 不修改 Aether 任何代码；仅基于现有能力（user_groups + billing_plans + membership_group + daily_quota + 管理 API）规划设计

---

## Section 1: 背景与目标

企业内部自托管 Aether 号池，为员工提供大模型服务。员工经 Google SSO 自动注册入驻。需要一套**分组 + 套餐**双层机制，按用量分层、防止滥用失控。

核心诉求：
- 新注册员工默认无法随意使用（Default 分组锁死）
- 按用量（月度费用额度）分层，而非按角色/部门
- 额度耗尽硬切断，管理员手动提额
- 月度自动续期，运维成本低
- 管理员可随时调整分组权限（运维旋钮）

---

## Section 2: 关键机制发现（基于现有代码）

以下内容是设计的依据，来自对 Aether 现有实现的分析（`apps/aether-gateway/src/data/state/auth.rs`）：

### 2.1 分组权限叠加规则（OR 逻辑）

`union_group_list_policies`（auth.rs:1969-1994）的合并算法：

- 多分组权限是 **UNION（OR 逻辑）**：任一分组 `specific` 授予的模型/供应商/格式，用户即可访问
- 任一分组 `unrestricted` → 短路返回 `None` = **完全放开**
- `deny_all` 分组 → **不贡献任何权限，也不能否决其他分组**
- **关键陷阱**：用户只在一个 `deny_all` 分组时，结果是 `None` = 完全放开，**不是锁死**

推论：要真锁死用户，必须用 `specific` + **空列表**（结果为 `Some([])` = 什么都允许不了），而非 `deny_all`。

### 2.2 套餐与会员分组

`billing_plans.entitlements_json` 支持 3 种权益类型：
- `daily_quota`：每日 USD 额度，周期内每天重置
- `membership_group`：`grant_user_groups: [组ID]`，购买/分配后**动态把用户加进对应分组**，到期自动移除
- `wallet_credit`：钱包充值（本次方案不使用）

套餐类型由 entitlements 内容推断，无独立 type 字段。组合 `daily_quota` + `membership_group` = "混合套餐"。

### 2.3 套餐分配与续期

- `user_plan_entitlements` 无 auto_renew 字段，系统**不支持自动续期**
- 到期是被动计算（`status==active && starts<=now < expires`），无后台 worker 主动处理
- 重新 grant 同类型套餐时，旧的自动标记 `replaced`，新的生效

### 2.4 管理 API（续期脚本用）

| 用途 | 方法 + 路径 | 权限 |
|------|------------|------|
| 列出所有用户 | `GET /api/admin/users?limit=1000&skip=0` | admin:users |
| 查用户当前套餐 | `GET /api/admin/users/{id}/billing/entitlements` | admin:users |
| 分配套餐给用户 | `POST /api/admin/users/{id}/billing/grant-plan` `{plan_id, reason?}` | admin:users |
| 创建分组 | `POST /api/admin/user-groups` | admin:users |
| 创建套餐 | `POST /api/admin/billing/plans` | admin:billing |
| 设系统默认组 | `PUT /api/admin/user-groups/default` `{group_id}` | admin:users |
| 为用户生成 API Key | `POST /api/admin/users/{id}/api-keys` `{name?}` | admin:users |
| 更新分组 | `PUT /api/admin/user-groups/{id}` | admin:users |

认证：management token（`mgmt_` 前缀，带 `admin:users`/`admin:billing`，过 IP 白名单）。

**默认组机制**：`PUT /api/admin/user-groups/default` 把组 ID 写入 system_config 表键 `default_user_group_id`；新 SSO 用户自动加入该组（见 2.5）。`GET /api/admin/user-groups` 返回的 `is_default` 是前端按此配置键实时计算的标志（非数据库列）。

**查套餐响应字段**（续期脚本依赖）：`GET .../entitlements` 返回 `{ items: [...], total }`，每项含 `active`（bool，= `status==active && starts<=now < expires`）、`plan_id`、`expires_at`（RFC3339）、`entitlements`（权益快照）。

### 2.5 已验证的关键机制（代码实证）

以下为设计基石，已对照源码确认：

| 机制 | 行为 | 出处 |
|------|------|------|
| **SSO 自动入默认组** | 新 OAuth 用户创建时调用 `assign_default_group_to_self_registered_user`，自动加入 `DEFAULT_USER_GROUP_CONFIG_KEY` 配置的默认组（无配置则用 built-in 默认组） | `oauth/identity_repo.rs:242` → `user_lifecycle.rs:12-58` |
| **membership_group 到期移除** | **被动重算**：每次鉴权时 `active_membership_group_ids_for_user` 重算 active 权益，过期者（`expires_at<=now`）直接排除，**不删行、无 worker** | `data/state/auth.rs:1839-1911` |
| **daily_quota 合并** | 多个 active daily_quota 权益**相加**（total = 各 grant 之和），非取 max/替换 | `adapters/*/src/billing.rs`（`find_user_daily_quota_availability`） |
| **跨档调级触发 replaced** | 重新 grant 时按 **entitlement type** 匹配（非 plan_id）：新套餐若含 `daily_quota`/`membership_group`，则把用户所有同类型 active 旧权益标记 `replaced` | `adapters/*/src/wallet.rs:3702-3782` |

**推论**：
- 默认组不是 `is_default` 数据库列，而是系统配置键 `DEFAULT_USER_GROUP_CONFIG_KEY` 指向的组。本方案把 Default 组设为该配置目标即可。
- 跨档调级（如基础→高级）走 grant，旧基础套餐因同 type 被 `replaced`，**不会双 daily_quota 并存**；续期脚本只需重新 grant 同 plan_id，旧档自动 replaced。
- 唯一可能产生双 daily_quota 的边缘：新套餐的 entitlement 集合是旧套餐的真子集（如旧含 daily_quota+membership_group，新仅 membership_group）。本方案的 3 档套餐 entitlement 结构一致，不会触发此边缘情况。

---

## Section 3: 设计方案

### 3.1 分组设计（4 个常驻分组）

| 分组 | allowed_models | allowed_providers | allowed_api_formats | rate_limit | is_default | 角色 |
|------|---------------|-------------------|---------------------|-----------|-----------|------|
| **Default** | specific `[]` | specific `[]` | specific `[]` | system | ✓ | SSO 自动入组，真锁死 |
| **基础组** | unrestricted | unrestricted | unrestricted | system | ✗ | $0.5/天 |
| **标准组** | unrestricted | unrestricted | unrestricted | system | ✗ | $5/天 |
| **高级组** | unrestricted | unrestricted | unrestricted | system | ✗ | $20/天 |

要点：
- **Default 组用 `specific` + 空列表锁死**，不使用 `deny_all`（见 2.1）
- 三档正式分组默认 `unrestricted`（模型范围一致），管理员可随时改为 `specific` 做临时限权（运维旋钮）
- 分组是"权限容器"，真正分层在套餐额度
- `rate_limit_mode = system` 表示沿用系统默认限流（不按组单独设限），管理员可在分组上改 `custom` 做限流分层；本方案默认不分层（YAGNI）

**初始置备**：4 个分组通过 `POST /api/admin/user-groups` 创建并配置权限；其中 Default 组的 ID 需写入系统配置键 `DEFAULT_USER_GROUP_CONFIG_KEY`（或依赖 built-in 默认组机制）。3 个月卡套餐通过 `POST /api/admin/billing/plans` 创建，`membership_group` 权益的 `grant_user_groups` 指向对应分组 ID。全部为既有 admin API 操作，无需改代码或 DB 迁移。

### 3.2 套餐设计（3 个混合月卡）

| 套餐 | daily_quota (USD/天) | membership_group | duration | 月预算(≈) |
|------|---------------------|------------------|----------|----------|
| 基础月卡 | 0.5 | 基础组 | 30天 | ~$15 |
| 标准月卡 | 5 | 标准组 | 30天 | ~$150 |
| 高级月卡 | 20 | 高级组 | 30天 | ~$600 |

要点：
- 套餐 = `daily_quota` + `membership_group`，不含 `wallet_credit`
- 月度预算 ≈ 日额度 × 30
- 全天额度耗尽 → 硬切断（拒绝请求）
- 提额 = 管理员重新分配更高档套餐

### 3.3 权限叠加与交互

- 用户分配正式套餐后，同时存在 Default（锁死）+ 正式组（unrestricted）
- OR 逻辑下，正式组 unrestricted 短路优先解锁 → 分配即生效，无需手动移出 Default
- 套餐过期 → 动态移出正式组 → 回到 Default 锁死（自动回收）

### 3.4 运维生命周期

| 场景 | 操作 |
|------|------|
| 入职注册 | Google SSO 登录 → 自动建账户 + 进 Default 锁死 |
| 申请开通 | 员工申请用量层级 → 管理员后台分配对应套餐 |
| 立即生效 | 系统动态加进对应分组 + 开通 daily_quota |
| 月度续期 | cron 每天跑，到期前 3 天同 plan_id 重新 grant |
| 调级 | 分配新套餐 → 旧同类型套餐自动 replaced |
| 离职/违规 | 禁用账户 or 不续期 → 到期自动回收 |
| 临时限权 | 管理员直接改分组 `allowed_models` 为 specific |

### 3.5 续期脚本（运维侧，不改 Aether 代码）

```
每天 cron 触发：
  1. GET /api/admin/users?limit=1000            → 所有用户（分页 skip 直到 has_more=false）
  2. for each user.id:
       GET /api/admin/users/{id}/billing/entitlements
       if 存在 active==true 且 expires_at - now ≤ 3天:
         POST /api/admin/users/{id}/billing/grant-plan
           { plan_id: <原plan_id>, reason: "auto-renewal" }
```

- 提前 3 天续期，避免到期空窗
- 认证用 management token（admin:users 权限，过 IP 白名单）
- **starts 语义假设**：重新 grant 即时生效（`starts=now`），旧同类型套餐被标记 `replaced`；因提前 3 天触发，用户实际额度窗口为约 33 天（30 天 + 提前 3 天重叠），月预算估算按 ~33 天计更稳妥，不视为空窗或浪费

### 3.6 监控

- 用户前端自见当日/月度用量（现有 usage 页）
- 管理员定期看统计页 + 分组用量 Top 排名
- 无需额外告警系统（YAGNI）

---

## Section 4: 明确排除（YAGNI）

- 不修改任何 Aether 代码（含 auto_renewal 功能）
- 不使用 `wallet_credit` 附赠余额
- 不按角色/部门分层，仅按用量
- 无自动提额/宽限期/部门预算封顶
- 不处理多组叠加风险（如员工同时被分入基础组+高级组，OR 逻辑下取高级权限，接受为预期行为）
- API Key 层约束暂不单独设计

---

## Section 5: Acceptance Criteria

1. 新建 Google SSO 账户自动落入 Default 组，未分配套餐前发起任意模型请求均被拒绝
2. Default 组的 `allowed_models/providers/api_formats` 均为 `specific` 模式且值为空列表
3. 三个常驻正式分组（基础/标准/高级）均存在且 `membership_group` 套餐可正确动态加组
4. 三个混合月卡套餐的 `daily_quota` 分别为 $0.5/$5/$20 每天，duration 30 天
5. 分配任意正式套餐后，用户立即可用且受对应日额度约束；全天额度耗尽返回拒绝
6. 套餐过期后用户自动回到 Default 锁死状态
7. 续期脚本对"到期前 3 天内"的 active 套餐执行同 plan_id 重新 grant，且旧套餐标记 replaced
8. 管理员可直接修改正式分组权限并立即生效于组内所有人
9. 运维手册（`docs/runbooks/2026-08-27-aether-group-plan-management.md`）存在，覆盖初始置备、日常操作、续期脚本部署、监控排障、应急流程 5 节

---

## Section 6: 交付物与下游说明

### 6.1 交付物

除本设计文档外，实施完成后还需产出一份**运维手册（Runbook）**，覆盖管理员日常操作，作为本方案的落地配套：

- 位置：`docs/runbooks/2026-08-27-aether-group-plan-management.md`
- 内容至少包含：
  1. **初始置备步骤** — 用 `POST /api/admin/user-groups` 建 4 个分组（含 Default 配置键写入）、用 `POST /api/admin/billing/plans` 建 3 个月卡套餐（entitlements 完整 JSON 示例）
  2. **日常操作** — 分配/调级/回收套餐的 admin 后台路径与 API 示例；临时改分组权限（运维旋钮）的操作
  3. **续期脚本部署** — cron 脚本的完整内容、management token 准备、crontab 配置、运行验证与日志检查
  4. **监控排障** — 用量页查看路径；常见情况处理（员工反馈"用不了"的排查树：是否还在 Default 组 / 套餐是否到期 / 额度是否耗尽）
  5. **应急流程** — 临时提额、违规封禁、离职回收的标准动作

运维手册与本 spec 同步提交，纳入实施验收（Acceptance Criteria 增补：运维手册存在且覆盖上述 5 节）。

### 6.2 下游说明（Notes for downstream）

- 若后续需要"分组自动继承套餐"（免双轨操作），需改 `user_groups` + `user_plan_entitlements` 增加组级绑定 — 超出本次无代码改动约束
- 若需要自动续期，需新增 schema 字段 + worker + 续期逻辑 — 本次用 cron 脚本替代
- 若需要部门预算封顶，可基于 `features/usage` 统计页扩展独立视图
