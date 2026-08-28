# Aether 号池分组与套餐管理 — 运维手册

> 配套设计：docs/superpowers/specs/2026-08-27-group-plan-management-design.md
> 配套计划：docs/superpowers/plans/2026-08-27-group-plan-management.md
> 零代码改动，全部通过管理后台 UI + 既有一键脚本完成。

## §1 初始置备

### 方式 A：一键脚本（推荐）

```bash
export AETHER_BASE="https://aether.example.com"
export MGMT_TOKEN="mgmt_xxx"   # admin:users + admin:billing，过 IP 白名单
bash scripts/aether/provision.sh
# 自动创建 4 分组 + 3 套餐 + 设默认组，id 追加到 .env
```

脚本幂等（重复运行复用已存在同名项），完成后可在 UI 验证。

### 方式 B：管理后台 UI 手动置备

#### 建 4 个分组

进入 **管理后台 → 分组管理** 页面，依次新建：

| 分组名 | allowed_providers | allowed_api_formats | allowed_models | rate_limit | 说明 |
|--------|-------------------|---------------------|---------------|------------|------|
| **Default** | specific → 空 | specific → 空 | specific → 空 | system | 新员工自动入组，锁死 |
| **Basic** | unrestricted | unrestricted | unrestricted | system | 基础档，额度由套餐控制 |
| **Standard** | unrestricted | unrestricted | unrestricted | system | 标准档 |
| **Premium** | unrestricted | unrestricted | unrestricted | system | 高级档 |

> ⚠️ **Default 必须用 specific + 空列表**，不能用 deny_all（分组权限 OR 叠加下 deny_all 无法否决其他组）。

创建后，在 Default 组上点击 **「设为默认组」**（或在列表中将其标记为默认），确保新 SSO 用户自动落入此组。

#### 建 3 个月卡套餐

进入 **管理后台 → 套餐管理** 页面，点击 **「新建套餐」**，选择 **「混合套餐」** 模板：

**基础月卡**：
- 标题：`基础月卡`
- price_amount：`0.01`（企业内部免费使用，API 要求正数）
- duration：`month` / `1`
- entitlements → daily_quota：`0.5`，timezone `Asia/Shanghai`
- entitlements → membership_group：选择 `Basic` 分组

**标准月卡**：
- 标题：`标准月卡`
- price_amount：`0.01`
- entitlements → daily_quota：`5`
- entitlements → membership_group：选择 `Standard` 分组

**高级月卡**：
- 标题：`高级月卡`
- price_amount：`0.01`
- entitlements → daily_quota：`20`
- entitlements → membership_group：选择 `Premium` 分组

### 验证

进入 **分组管理** 页：确认 Default 组为默认组（标记 ✓），三处权限为 specific 空列表。

进入 **套餐管理** 页：确认 3 个月卡各含 daily_quota + membership_group 权益。

---

## §2 日常操作

### 分配套餐（新员工开通）

1. 进入 **管理后台 → 用户管理**
2. 找到目标用户，点击进入用户详情
3. 在 **套餐/权益** 区域，点击 **「分配套餐」**
4. 选择对应档位（基础月卡 / 标准月卡 / 高级月卡）
5. 确认分配

效果：系统自动将用户动态加进对应分组 + 开通 daily_quota，**立即可用**。

### 调级（升/降档）

1. 进入 **用户管理 → 目标用户 → 套餐/权益**
2. 点击 **「分配套餐」**，选择新档位
3. 后端自动将旧同类型套餐标记 replaced，新套餐立即生效

> 例：基础→标准 → 分配标准月卡，旧基础权益自动 replaced，用户权限和额度立即更新。

### 回收（离职/违规）

- **自然回收**：不续期 → 套餐到期后系统自动从分组移出、回到 Default 锁死（被动重算，无需手动）。
- **立即封禁**：在 **用户管理** 页禁用账户（关闭 `is_active` 开关）。

### 临时限权（运维旋钮）

1. 进入 **分组管理** → 编辑目标分组
2. 修改权限配置（如把 `allowed_models` 从 unrestricted 改为 specific，列出允许的模型）
3. 保存

改动**立即对组内所有成员生效**。用完改回 unrestricted。

---

## §3 续期脚本部署

### docker-compose cron service（推荐）

cron service 已内置在 `docker-compose.yml` 和 `docker-compose.single-node.yml` 中，随主服务一起启动：

```bash
docker compose up -d
# cron 容器自动每天 03:07（Asia/Shanghai）执行续期
docker logs -f aether-cron
```

若需修改调度时间：编辑 `scripts/aether/crontab`，然后重建 cron 容器：
```bash
docker compose up -d --build cron
```

### 宿主机 crontab（无 docker 环境）

```bash
(crontab -l 2>/dev/null; echo "7 3 * * * $(pwd)/scripts/aether/renew-plans.sh $(pwd)/.env >> /var/log/aether-renew.log 2>&1") | crontab -
```

### 验证

```bash
bash scripts/aether/renew-plans.sh .env 2>&1
# 首次运行预期：renewed=0 failed=0（无套餐进入 3 天窗口）
# 真实续期发生在套餐进入"现在+3天"窗口时，由 cron 自动触发
```

### 注意

- `.env` 含 `MGMT_TOKEN`，已在 `.gitignore` 中忽略。
- docker-compose 用户：cron 由容器自动调度，无需手动注册 crontab。
- 宿主机用户：cron 用绝对路径；`MGMT_TOKEN` 过期或 IP 白名单变更时需更新 `.env`。

---

## §4 监控排障

### 查看用量

- **员工**：登录后在左侧菜单「用量统计」查看当日/月度用量。
- **管理员**：管理后台 → 统计页，查看分组用量 Top 排名。

### "用不了"排查树

1. **是否还在 Default 组、未分配任何套餐？**
   → 管理后台 → 用户管理 → 检查用户分组；未分配则分配对应月卡。

2. **套餐是否已过期？**
   → 管理后台 → 用户管理 → 用户详情 → 套餐/权益，查看 active/expires_at 状态。过期则需重新分配。

3. **当日额度是否耗尽？**
   → daily_quota 用尽即硬切断（429/403），次日自动重置。或管理员临时分配更高档套餐提额。

4. **Default 锁死仍在生效？**
   → 确认已分配正式套餐（membership_group 已加组）；OR 逻辑下正式组 unrestricted 应覆盖 Default。

### 排障路径

| 排查内容 | 管理后台路径 |
|---------|------------|
| 查用户套餐/权益 | 用户管理 → 用户详情 → 套餐/权益 |
| 查用户所属分组 | 用户管理 → 用户详情 → 分组 |
| 查分组权限配置 | 分组管理 → 编辑分组 → 权限设置 |
| 查套餐 entitlements | 套餐管理 → 编辑套餐 → 权益配置 |

---

## §5 应急流程

### 临时提额

在 **用户管理 → 用户详情 → 套餐/权益** 中，直接分配更高档月卡（旧档自动 replaced）。用完后分配回原档。

### 违规封禁

在 **用户管理** 页禁用目标账户（关闭活跃状态开关），或在 **分组管理** 中将其移出所有正式分组 → 回 Default 锁死。

### 离职回收

禁用账户 + 停止续期；到期后系统自动回收分组与额度，无需手动操作。

### 续期脚本故障

- 检查 `.env` 中 `MGMT_TOKEN` 是否过期、IP 白名单是否包含 cron 运行环境 IP。
- docker-compose：`docker logs aether-cron` 查看 cron 输出。
- 暂停续期：注释 crontab 中对应行（宿主机）或 `docker compose stop cron`（容器）。
- 手动兜底：在 **用户管理 → 用户详情 → 套餐/权益** 中重新分配套餐。
