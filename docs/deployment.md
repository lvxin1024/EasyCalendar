# 部署方案

## 1. 部署目标

用户的目标操作是：准备配置、执行一条命令、得到可访问的单用户实例。用户不需要修改源码、Dockerfile、Worker 路由或数据库 SQL。所有非秘密参数放 `config/app.yaml`，秘密放 `config/secrets.env` 或平台 secret store。

Cloudflare 基础部署入口已实现为：

```bash
./scripts/setup.sh --config config/app.yaml
```

当前脚本支持 `validate`、`install`、`create`、`migrate`、`deploy` 和 `status`；完整生命周期仍需补充 `backup` 和 `rollback`。

## 2. 首选：Cloudflare 一站式部署

### 资源

- Workers：同步 API、订阅管理和可选 AI proxy。
- D1：Item、Collection、Subscription、change log 和配置元数据。
- R2：加密备份、JSON 导出和较大附件，可选。
- Cron Triggers：刷新 ICS、清理过期日志和备份。
- Pages：可选 Web/PWA 静态资源。

### 用户准备

1. 安装 Node.js、npm 和 Wrangler。
2. 登录自己的 Cloudflare 账户。
3. 复制 `config/app.example.yaml` 为 `config/app.yaml`。
4. 填写域名、时区、实例名称和部署 provider。
5. 在 `config/secrets.env` 填写或让脚本生成 `ADMIN_TOKEN`。
6. 执行 `./scripts/setup.sh --config config/app.yaml`。

### 脚本应自动完成

1. 检查 Node、Wrangler、配置 schema 和 Cloudflare 登录状态。
2. 生成 Worker 名称、D1 数据库名称和环境变量映射，不要求用户编辑 `wrangler.toml`。
3. 创建 D1 并执行按版本编号的 migrations。
4. 生成或设置 `ADMIN_TOKEN`，秘密使用 `wrangler secret put`。
5. 部署 Worker 和可选 Pages。
6. 配置 Cron Trigger。
7. 调用 `/v1/health` 和 `/v1/capabilities` 做 smoke test。
8. 输出客户端要填的 `server_url`，但不输出 token 原文到 CI 日志。

### 生产安全

- 强制 HTTPS。
- CORS 只允许 `config/app.yaml` 中的客户端域名。
- Token 只通过 Cloudflare secret 管理。
- D1 migrations 执行前自动备份或至少创建可恢复的变更点。
- 订阅刷新限制 URL 协议、重定向次数、响应大小、DNS 私网地址和超时。
- AI proxy 默认关闭，开启后限制 provider URL、输入长度和响应大小。

## 3. 备选：Docker Compose

### 目标结构

```text
docker compose
  api       # API + migrations + ICS cron worker
  volume    # SQLite、备份和 widget snapshot
  caddy     # 可选 HTTPS reverse proxy
```

第一版不需要 Redis 或 Postgres。数据库文件和备份目录必须挂载到持久卷，容器重建不能丢数据。

### 用户操作

```bash
cp config/app.example.yaml config/app.yaml
cp config/secrets.example.env config/secrets.env
# 编辑 config/app.yaml 和 config/secrets.env
./scripts/setup.sh --config config/app.yaml
```

脚本生成或校验 `docker-compose.generated.yml`，然后执行迁移、启动和 smoke test。用户不直接编辑生成文件。

## 4. 配置、秘密和文件权限

| 内容 | 位置 | Git |
| --- | --- | --- |
| 时区、端口、域名、功能开关 | `config/app.yaml` | 不提交真实环境文件 |
| token、AI key、OAuth secret | `config/secrets.env` 或平台 secret | 永不提交 |
| 配置模板 | `config/app.example.yaml` | 提交 |
| SQLite | `app.data_dir` | 不提交 |
| JSON/ICS 备份 | `storage.backup_dir` | 不提交或上传加密 R2 |
| Worker 生成配置 | 临时 build 目录 | 不提交 |

`config/` 在项目模板中提供示例文件和 `.gitignore` 规则；用户可以通过备份 `config/app.yaml` 迁移实例，但秘密应重新生成或通过 secret store 迁移。

## 5. 升级和回滚

### 升级

1. `setup.sh validate` 检查配置和版本兼容。
2. 备份 SQLite 或 D1 导出。
3. 执行向前 migration。
4. 部署新 API。
5. 运行 health、capabilities 和读写 smoke test。
6. 客户端按 API/schema 版本检查兼容性。

### 回滚

- 应用代码回滚必须可在旧 schema 上运行。
- 破坏性 schema 变更分成 expand、应用迁移、contract 三步，不允许一步删除旧字段。
- migration 失败时停止部署，不自动删除数据库。
- 恢复数据前要求显式 `--restore`，避免错误配置覆盖现有实例。

## 6. 备份和灾难恢复

- 用户可随时生成全量 JSON 备份。
- Event 可额外导出 ICS，但 ICS 不是完整数据备份。
- Cloudflare 版按 Cron 导出 D1 到 R2；Docker 版按 Cron 复制 SQLite 到备份目录。
- 备份文件包含 `schema_version` 和生成时间，不包含秘密。
- 恢复流程必须先导入临时实例并执行校验，再切换生产 URL。

## 7. 当前实现差距

当前实现边界：

- `scripts/setup.sh` 已能校验 Cloudflare 配置、创建 D1、执行 migration、部署 Worker、写入 token secret 和检查 health。
- Worker 当前只提供服务端骨架；部署成功不代表 T2.2 push/pull 已可用。
- 自动 D1 备份、回滚、Cron/R2、Pages 和 Docker Compose 尚未实现，因此仍不宣传为完整的一键部署生命周期。
