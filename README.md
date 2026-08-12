<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="public/brand/easycalendar-github-hero.svg">
    <img src="public/brand/easycalendar-github-hero.svg" alt="EasyCalendar — local-first calendar & due manager" width="100%" />
  </picture>
</p>

<h1 align="center">EasyCalendar</h1>

<p align="center">
  <strong>本地优先 · 可自托管 · 离线可用</strong>
  <br />
  Local-first, self-hostable personal calendar &amp; due manager.
</p>

<p align="center">
  <a href="https://github.com/lvxin1024/easycalendar/actions"><img src="https://github.com/lvxin1024/easycalendar/actions/workflows/tests.yml/badge.svg" alt="Tests" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  <a href="https://www.python.org/downloads/"><img src="https://img.shields.io/badge/python-3.11%2B-3776AB?logo=python" alt="Python 3.11+" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/flutter-3.44.9-02569B?logo=flutter" alt="Flutter 3.44.9" /></a>
</p>

<p align="center">
  <img src="public/brand/easycalendar-icon.svg" alt="EasyCalendar icon" width="128" height="128" />
</p>

---

## 这是什么？ / What is this?

**EasyCalendar** 是一个面向个人的日程与 Due 管理工具。你可以离线使用它，也可以连接自己的同步服务在多设备间同步数据。

- 🇨🇳 用中文自然语言写日程（"明天上午9点开会"），规则引擎自动解析
- 📅 日/周/月视图、Due 管理、标签筛选、循环日程
- 💻 macOS / Windows / Android 三平台 Flutter 桌面客户端
- 🔒 数据完全在你手里：本地 SQLite 存储，可选自托管同步服务
- 🤖 可选 AI 助手（OpenAI / Ollama），确认后才写入正式日程
- 📡 支持 ICS 日历订阅（通过同步服务抓取）

> **EasyCalendar** is a personal calendar & due manager. Use it fully offline, or connect your own sync server for multi-device sync. Natural-language parsing, day/week/month views, due management, tag filters, recurrence — all stored in your local SQLite database.

---

## ✨ 功能 / Features

| 功能 Feature | 说明 Description |
|---|---|
| 📝 中文规则解析 | 把"明天上午9点开会"解析为待确认的日程候选，不依赖 AI |
| 📅 日历视图 | 单日 24 小时时间轴、周视图、月视图，重叠事件自动分栏 |
| ✅ Due 管理 | 任务截止日期追踪，日历视图顶部置顶显示 |
| 🏷️ 标签筛选 | 自定义标签颜色，跨视图一致筛选 |
| 🔁 循环日程 | 每天/工作日/每周/每月/每年 RRULE，范围查询展开 |
| 🤖 AI 助手 | OpenAI-compatible / Ollama 多 Provider，候选预览确认后写入 |
| 📡 ICS 订阅 | 外部日历只读导入独立 Collection，ETag 条件抓取 |
| 📦 导入导出 | JSON 全量备份、ICS 文件导入，预览后提交 |
| 🗑️ 回收站 | 软删除恢复，乐观锁幂等保护 |
| 🔔 通知提醒 | 平台通知适配接口，提醒改期自动协调 |
| 🔄 自动同步 | outbox push / cursor pull，确定性冲突恢复，网络恢复自动重试 |
| 🪟 桌面窗口 | macOS/Windows 透明度、置顶、点击穿透，桌面日历 overlay |
| 🧩 macOS Widget | App Group 离线 timeline，快照损坏容错 |

---

## 🚢 部署 / Deployment

EasyCalendar 由三个独立组件组成，可以根据需要分别部署。

### 组件总览

| 组件 | 技术栈 | 说明 |
|---|---|---|
| **Python Core** | Python 3.11+ / FastAPI / SQLite | 规则解析、ICS 抓取、AI 助手、导入导出 API |
| **Flutter Client** | Flutter 3.44.9 / Dart / SQLite | macOS / Windows 桌面端和 Android 移动端，离线可用 |
| **Sync Server** | TypeScript / Cloudflare Workers / D1 | 多设备同步（可选，离线使用不需要） |

### 1. Python Core

规则解析、导入导出和 AI 助手等服务端功能的核心。它可以部署到已有远程服务器，但目前不承担 Flutter 客户端的多设备同步。

```bash
git clone https://github.com/lvxin1024/easycalendar.git
cd easycalendar

# 安装依赖
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 配置
cp config/app.example.yaml config/app.yaml   # 编辑时区、端口等
cp config/secrets.example.env config/secrets.env  # 设置 token、AI key

# 启动
.venv/bin/python run.py
# → API: http://localhost:8000
# → OpenAPI docs: http://localhost:8000/docs
```

不复制配置文件也可以以安全默认值启动。Core 不强制依赖 Sync Server，可以独立运行。

部署到远程服务器时，建议用 systemd 等进程管理器运行，并在前面配置 Caddy 或 Nginx HTTPS 反向代理；不要把 `config/secrets.env` 提交到 Git。当前 Flutter 客户端设置页中的“API 地址”用于同步协议，必须填写下文的 Cloudflare Worker 地址，不能填写 Python Core 地址。

### 2. Flutter 客户端

macOS / Windows 桌面端和 Android 移动端。内置 SQLite 本地存储，断网也能完整使用。

```bash
cd client
cp ../config/client.example.json ../config/client.json

# 安装依赖 + 生成平台 runner
flutter pub get

# macOS
flutter run -d macos
# 或打包：flutter build macos

# Windows（需在 Windows host 执行）
flutter run -d windows
# 或打包：flutter build windows

# Android（需 Android SDK）
flutter run -d <device-id>
# 或打包：flutter build apk
```

也可以使用脚本：

```bash
./scripts/setup-client.sh   # 环境初始化
./scripts/run-client.sh     # 启动（自动检测平台）
```

`config/client.json` 只提供首次启动的默认值。安装后可以直接在“设置 > 连接”中覆盖 API 地址、设备 ID 和默认 Collection，无需重新编译；具体填写方式见下一节。

### 3. Sync Server（Cloudflare Worker/D1）

多设备同步服务。部署后各客户端通过它交换 outbox 变更。

```
┌──────────┐     ┌──────────────────┐     ┌──────────┐
│  macOS   │ ←→  │  Cloudflare       │ ←→  │  Windows │
│  Client  │     │  Worker + D1      │     │  Client  │
└──────────┘     └──────────────────┘     └──────────┘
```

Cloudflare Worker + D1 是当前唯一实现的多设备同步服务器。配置和部署命令在一台装有本仓库、Node.js 22 的开发电脑上执行即可，Worker 和数据库最终运行在你的 Cloudflare 账户中，不需要把 Worker 部署到已有远程服务器。

**前提**：Node.js 22、Cloudflare 账号，以及一个准备使用的 `workers.dev` 地址或已接入 Cloudflare 的自定义域名。

先在仓库根目录创建不会提交到 Git 的本地配置：

```bash
cp config/app.example.yaml config/app.yaml
cp config/secrets.example.env config/secrets.env
```

编辑 `config/app.yaml`。以下配置可直接作为 Cloudflare 部署模板；把域名和实例名替换成自己的值：

```yaml
app:
  name: EasyCalendar
  instance_name: lvxin-easycalendar
  timezone: Asia/Shanghai
  locale: zh-CN

server:
  mode: cloudflare
  public_url: https://calendar.example.com
  cors_allowed_origins:
    - https://calendar.example.com

storage:
  driver: d1
  sqlite_path: ./data/app.sqlite3
  backup_dir: ./data/backups

sync:
  enabled: true
  pull_limit: 200
  retry_limit: 8

deployment:
  provider: cloudflare
  auto_migrate: true
  auto_backup_before_migrate: true
```

- `app.instance_name` 只能包含小写字母、数字和连字符，会生成 `<instance_name>-server` Worker 和 `<instance_name>-db` D1 数据库。
- `server.public_url` 必须是最终公开的 HTTPS 地址，不能带路径。可填写 `https://<worker>.<account>.workers.dev`，也可填写 Cloudflare 中已托管 DNS 的自定义域名。
- `cors_allowed_origins` 不接受 `*`。原生 macOS、Windows、Android 客户端不依赖浏览器 CORS；暂时可以填写与 `public_url` 相同的 origin，未来增加 Web 客户端时再加入其 HTTPS origin。

生成至少 32 字符的随机访问令牌：

```bash
openssl rand -hex 32
```

把输出只写入 `config/secrets.env`：

```dotenv
ADMIN_TOKEN=<上一步生成的 64 位十六进制字符串>
AI_API_KEY=
```

然后安装 Worker 依赖、登录 Cloudflare、校验并部署：

```bash
./scripts/setup.sh install
cd server
npx wrangler login
cd ..

./scripts/setup.sh validate --config config/app.yaml
./scripts/setup.sh --config config/app.yaml
```

登录授权发生在浏览器中，选择实际持有域名/D1 的 Cloudflare 账户。部署脚本会自动创建 D1 数据库、执行 migration、部署 Worker、写入 `ADMIN_TOKEN` secret，并请求 `/v1/health` 验证结果。不要手工编辑 `server/wrangler.jsonc`；生成状态保存在已忽略的 `server/.generated/`。

#### 客户端设置

在每台设备打开“设置 > 连接”，填写并保存：

| 设置项 | 如何填写 | 示例 |
|---|---|---|
| **API 地址** | 所有设备填写同一个 Cloudflare Worker HTTPS 地址 | `https://calendar.example.com` |
| **访问令牌** | 所有设备填写 `config/secrets.env` 中同一个 `ADMIN_TOKEN` | 上面生成的 64 位字符串 |
| **设备 ID** | 每次安装必须唯一；2–128 位，只能使用字母、数字、点、下划线和连字符 | `lvxin-macbook`、`lvxin-phone`、`lvxin-windows` |
| **默认 Collection ID** | 需要共享默认日历的设备填写相同值 | `collection_local` |
| **默认 Collection 名称** | 本机显示名称，可按需要填写 | `我的日程` |
| **同步** | 打开开关，保存后点击“立即同步” | 开启 |

这些设置会持久化在当前安装中，并覆盖构建时的 `EASYCALENDAR_API_URL`、`EASYCALENDAR_DEVICE_ID`、`EASYCALENDAR_DEFAULT_COLLECTION_ID` 和默认 Collection 名称，因此普通用户不需要编辑环境变量或重新构建应用。

设备 ID 应长期保持稳定。修改它不会破坏尚未上传的旧变更，客户端会按旧、新设备 ID 分批上传；但日常使用中不要频繁修改。修改默认 Collection ID 只影响之后新建的日程，会创建或选择新的 Collection，不会自动迁移旧 Collection 中已有数据。

#### Cloudflare 与已有远程服务器如何分工

- **Cloudflare 账户**：配置和运行 Worker、D1、同步域名及 `ADMIN_TOKEN`，客户端同步地址指向这里。
- **已有远程服务器/VPS**：可选，用来运行 Python/FastAPI Core，并通过 Caddy/Nginx 提供 HTTPS；它目前与 Flutter 同步链路相互独立。
- **客户端设备**：各自保存本地 SQLite 数据；需要多设备同步时连接同一个 Worker，但使用各自唯一的设备 ID。

> 当前尚未实现 Docker Compose 一键部署、全套 VPS 同步部署和自动 D1 备份/回滚。不要把 Python Core URL 填成同步 API 地址。

### 运行测试

```bash
./scripts/test.sh          # Python 离线测试
cd client && flutter test  # Flutter 客户端测试
cd server && npm test      # Worker 测试
```

---

## 🛠️ 技术实现 / Tech Stack

| 层 | 技术 |
|---|---|
| 客户端 | Flutter 3.44.9, Dart, SQLite (drift), platform channels |
| 核心服务 | Python 3.11+, FastAPI, SQLite, icalendar, RRULE 展开引擎 |
| 同步服务 | TypeScript, Cloudflare Workers, D1, Hono, outbox/cursor 协议 |
| AI | OpenAI-compatible / Ollama Provider, Candidate 确认流程 |
| 解析 | 中文规则引擎 (date_extractor + event_detector), 不依赖 AI |

离线优先架构：客户端 `LocalItemRepository` 直连本地 SQLite，所有 CRUD 即时完成。同步层通过 outbox push / cursor pull 异步交换变更，确定性 LWW 冲突恢复。ICS 订阅由服务端抓取（ETag/Last-Modified 条件请求、SSRF 防护），解析后通过同步协议下发客户端。

---

## 📋 待办事项 / TODO

按优先级排列的已知问题和未完成工作。

### 待修复 / Known Issues

| # | 问题 | 说明 | 优先级 |
|---|------|------|--------|
| 1 | **ICS 订阅需要 token** | 未配置同步服务时，订阅页面直接报错而非友好引导 | 高 |
| 2 | **Parser 覆盖有限** | 复杂时间范围、自然语言时长、重复规则需补充 fixture | 中 |
| 3 | **平台通知 adapter** | 接口和 InMemory 实现已完成，macOS/Windows/Android 真实系统通知待接入 | 中 |
| 4 | **自动备份未接入** | `auto_backup_before_migrate` 仍待实现 | 低 |
| 5 | **Android/Windows 原生验收** | macOS 已通过 Xcode 启动验收，Android 和 Windows 待对应 SDK 工具链 | 低 |
| 6 | **标签可复用** | 编辑标签时需手动输入，应列出已有标签供直接选择，避免重复和不一致 | 中 |

### 暂缓任务 / Deferred

| 任务 | 说明 |
|------|------|
| T7.1 Importer SDK | 统一外部日历导入契约（Google/Microsoft/飞书） |
| T7.2 外部适配器 | OAuth、最小权限、外部 ID 映射 |
| Docker Compose 部署 | 一键本地容器化部署 |
| Cloudflare Cron/R2 备份 | 自动 D1 导出 + R2 存储 |
| Windows Widget | 桌面小部件（macOS WidgetKit 已完成） |


## 🤝 贡献 / Contributing

项目主要服务一个人，欢迎 Issue 和 PR。

- 提交前运行 `./scripts/test.sh` 确保测试通过
- 每个功能独立 commit，不混合无关改动

> This project primarily serves a single user, but issues and PRs are welcome. Run tests before submitting, and keep commits focused.

---

## 📄 开源协议 / License

[MIT](LICENSE) © EasyCalendar

---

<p align="center">
  <sub>Made with ☕️ and 🗓️</sub>
</p>
