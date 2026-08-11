# 配置规范

## 目标

部署者只修改 `config/` 下的配置文件，不改源码、不改 Dockerfile、不改 Worker 路由。配置分为非敏感运行配置和敏感秘密配置，二者都由部署脚本读取。

Python 原型已经通过 `config/loader.py` 读取并校验本规范中的配置。尚未实现的 Worker、Flutter 和部署脚本在接入时必须复用同一字段语义。

## 文件布局

```text
config/
  app.example.yaml       # 提交到 Git，完整字段和安全默认值
  app.yaml               # 用户复制后修改，不提交
  secrets.example.env    # 提交字段名，不放真实值
  secrets.env            # 用户填写的秘密，不提交
  calendars/             # 本地 ICS 输出或 fixture
  environments/
    local.yaml            # 可选，本地覆盖
    production.yaml       # 可选，生产非敏感覆盖
```

配置合并顺序：默认值 < `app.yaml` < `environments/*.yaml` < 进程环境变量。秘密只从 `secrets.env`、部署平台 secret store 或环境变量读取。

## 推荐配置示例

```yaml
app:
  name: EasyCalendar
  instance_name: my-easycalendar
  timezone: Asia/Shanghai
  locale: zh-CN
  data_dir: ./data
  default_collection_id: collection_local
  default_collection_name: 我的日程
  default_collection_color: "#2563EB"

server:
  mode: local                    # local | cloudflare | docker
  host: 0.0.0.0
  port: 8000
  public_url: http://localhost:8000
  cors_allowed_origins:
    - http://localhost:8000

storage:
  driver: sqlite                 # sqlite | d1
  sqlite_path: ./data/app.sqlite3
  backup_dir: ./data/backups

sync:
  enabled: false
  pull_limit: 200
  retry_limit: 8

subscriptions:
  enabled: true
  refresh_cron: "0 */6 * * *"
  request_timeout_seconds: 20

assistant:
  enabled: false
  provider: rules                 # rules | openai_compatible | ollama
  base_url: http://localhost:11434/v1
  model: deepseek-v4
  timeout_seconds: 45
  max_input_chars: 20000

integrations:
  ical_output_dir: ./config/calendars
  google_credentials_file: ./config/google_credentials.json
  google_token_file: ./config/google_token.json
  outlook_tenant_id: common

widget:
  enabled: false
  snapshot_path: ./data/widget/snapshot.json

deployment:
  provider: docker               # docker | cloudflare
  auto_migrate: true
  auto_backup_before_migrate: true
```

## 配置矩阵

| 键 | 默认 | 必填 | 敏感 | 说明 |
| --- | --- | --- | --- | --- |
| `app.name` | `EasyCalendar` | 否 | 否 | UI、日志和 API title |
| `app.timezone` | `Asia/Shanghai` | 否 | 否 | 所有无时区输入的解释基准 |
| `app.data_dir` | `./data` | 否 | 否 | SQLite、备份、快照目录 |
| `app.default_collection_id` | `collection_local` | 否 | 否 | 空库首次使用时自动创建的本地 Collection ID |
| `app.default_collection_name` | `我的日程` | 否 | 否 | 默认 Collection 显示名 |
| `app.default_collection_color` | `#2563EB` | 否 | 否 | 默认 Collection 颜色，可设为空 |
| `server.mode` | `local` | 否 | 否 | 运行目标 |
| `server.public_url` | 空 | 生产必填 | 否 | 客户端同步地址 |
| `server.port` | `8000` | 否 | 否 | 本地或 Docker 端口 |
| `server.cors_allowed_origins` | 本地地址 | 生产必填 | 否 | 禁止默认 `*` |
| `storage.driver` | `sqlite` | 否 | 否 | 客户端使用 SQLite，Worker 使用 D1 |
| `storage.sqlite_path` | `./data/app.sqlite3` | 否 | 否 | 本地数据库路径 |
| `storage.backup_dir` | `./data/backups` | 否 | 否 | migration 前备份目录，待部署/备份任务接入 |
| `sync.enabled` | `false` | 否 | 否 | 是否启用同步 |
| `subscriptions.refresh_cron` | 每 6 小时 | 否 | 否 | ICS 刷新频率 |
| `assistant.provider` | `rules` | 否 | 否 | 无 key 时仍可运行规则 Parser |
| `assistant.base_url` | 空 | AI/Ollama 时必填 | 否 | OpenAI-compatible 地址 |
| `assistant.model` | 空 | AI 开启时必填 | 否 | 模型名称 |
| `assistant.max_input_chars` | `20000` | 否 | 否 | 单次 Candidate 提取允许的最大文本字符数 |
| `integrations.*` | 示例路径 | 对应接入时必填 | 否 | 第三方配置文件路径和租户 |
| `widget.snapshot_path` | `./data/widget/snapshot.json` | 否 | 否 | Widget 只读快照 |
| `deployment.provider` | `docker` | 否 | 否 | 一键部署目标 |
| `deployment.auto_migrate` | `true` | 否 | 否 | SQLite Repository 启动时执行向前 migration；关闭时 schema 不是最新版则拒绝启动 |
| `deployment.auto_backup_before_migrate` | `true` | 否 | 否 | 迁移前自动备份开关，当前尚未接入执行器 |
| `ADMIN_TOKEN` | 自动生成 | 同步必填 | 是 | 单实例 Bearer token |
| `AI_API_KEY` | 空 | 云端 AI 时必填 | 是 | AI Provider 密钥 |
| `GOOGLE_CLIENT_SECRET` | 空 | Google 接入时必填 | 是 | 仅放 secret store |

## 配置校验要求

- `server.public_url` 为 HTTPS 时，token 才允许通过非本地客户端使用。
- `sync.enabled=true` 时必须有 token、public URL 和持久化存储。
- `assistant.enabled=true` 且 provider 不是 `rules` 时必须有 base URL 和 model；云端 provider 还必须有 API key。
- `subscriptions.enabled=true` 时必须配置请求超时和 SSRF 规则。
- 部署前自动生成 `ADMIN_TOKEN`，并输出一次保存提示；之后不在日志中再次打印。
- 未知配置键默认拒绝启动，防止拼写错误导致用户以为设置生效。

## 环境变量覆盖

- `EASYCALENDAR_CONFIG`：指定主配置文件。
- `EASYCALENDAR_SECRETS`：指定秘密文件。
- `EASYCALENDAR_ENV`：加载 `config/environments/<name>.yaml`。
- `EASYCALENDAR__SERVER__PORT=9000`：使用双下划线覆盖任意嵌套字段。
- 现有 `API_HOST`、`API_PORT`、`API_DEBUG`、Google、Outlook 和 iCal 环境变量继续兼容。
