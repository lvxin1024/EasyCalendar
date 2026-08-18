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
- 📡 支持 ICS 日历订阅（客户端本地条件抓取）

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
| **Python Core** | Python 3.11+ / FastAPI / SQLite | 独立 API 与参考实现；Flutter 安装包的 ICS 功能不依赖它 |
| **Flutter Client** | Flutter 3.44.9 / Dart / SQLite | macOS / Windows 桌面端和 Android 移动端，离线可用 |
| **Sync Server** | TypeScript / Cloudflare Workers / D1 | 多设备同步（可选，离线使用不需要） |

### 1. Python Core

规则解析、导入导出和 AI 助手等服务端 API 的参考实现。它可以独立部署，但不承担 Flutter 客户端的多设备同步；Flutter 安装包的 ICS 文件传输和网址订阅已在本机完成。

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

部署到远程服务器时，建议用 systemd 等进程管理器运行，并在前面配置 Caddy 或 Nginx HTTPS 反向代理；不要把 `config/secrets.env` 提交到 Git。Flutter 设置页中的“功能服务地址”填写 Python Core 地址；“同步服务地址”填写下文的 Cloudflare Worker 地址，两者不能混用。

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

`config/client.json` 只提供首次启动的默认值。设备 ID 在首次启动时自动生成并持久化；安装后可以直接在“设置 > 连接”中维护 API 地址、设备名称和默认 Collection，无需重新编译；具体填写方式见下一节。

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
| **同步服务地址** | 所有设备填写同一个 Cloudflare Worker HTTPS 地址 | `https://calendar.example.com` |
| **功能服务地址** | 兼容 Python Core API 的可选地址；当前安装包本地功能不依赖 | `https://core.example.com` |
| **同步服务令牌** | Cloudflare Worker 的 `ADMIN_TOKEN`；需要同步的设备填写同一个值 | 上面生成的 64 位字符串 |
| **功能服务令牌** | Python Core 配置了 `ADMIN_TOKEN` 时填写；未配置鉴权时留空 | Core 实例自己的 token |
| **设备名称** | 用于区分设备，可按习惯修改 | `工作电脑`、`手机` |
| **设备 ID** | 首次启动自动生成并长期保存；通常无需修改，可在高级连接设置中复制或重建 | `device-<UUID>` |
| **默认 Collection ID** | 需要共享默认日历的设备填写相同值 | `collection_local` |
| **默认 Collection 名称** | 本机显示名称，可按需要填写 | `我的日程` |
| **同步** | 打开开关，保存后点击“立即同步” | 开启 |

这些设置会持久化在当前安装中，并覆盖构建时的 API 地址、默认 Collection 等初始值，因此普通用户不需要编辑环境变量或重新构建应用。`EASYCALENDAR_DEVICE_ID` 默认留空；仅定制部署需要预设 ID，普通 Release 安装会自动生成。

同步服务令牌与功能服务令牌使用不同的系统安全存储项，互不覆盖。Python Core 未配置 `ADMIN_TOKEN` 时允许无 token 访问，适合仅监听本机地址的场景；一旦配置 `ADMIN_TOKEN`，除 health/capabilities 外的 `/v1` API 都要求对应 Bearer token。把 Core 暴露到局域网或公网时必须配置 token 和 HTTPS。

设置页为同步服务和功能服务分别提供“测试连接”。检测会依次验证健康状态、API 版本、服务能力和令牌，不会创建或修改日历数据；DNS、TLS、超时、鉴权和能力不兼容会显示不同错误。

维护者推送与 `client/pubspec.yaml` 版本一致的 `vX.Y.Z` tag 后，Release 工作流会构建 Android APK/AAB、Windows 安装器与便携包、macOS DMG，并附带调试符号和 `SHA256SUMS.txt`。工作流要求预先配置 Android keystore、Windows 代码签名证书、Apple Developer ID 证书/Provisioning Profile 与公证账户 Secrets；任何签名材料缺失都会终止发布。

Release 仓库 Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`WINDOWS_CERTIFICATE_PFX_BASE64`、`WINDOWS_CERTIFICATE_PASSWORD`、`MACOS_CERTIFICATE_P12_BASE64`、`MACOS_CERTIFICATE_PASSWORD`、`MACOS_SIGNING_IDENTITY`、`MACOS_APP_PROVISION_PROFILE_BASE64`、`MACOS_WIDGET_PROVISION_PROFILE_BASE64`、`APPLE_ID`、`APPLE_APP_PASSWORD`、`APPLE_TEAM_ID`。证书文件均以 base64 内容保存，不写入仓库。

设备 ID 应长期保持稳定。高级设置中的“重建设备身份”不会破坏尚未上传的旧变更，客户端会按旧、新设备 ID 分批上传；只应在复制安装、身份冲突或排查同步问题时使用。修改默认 Collection ID 只影响之后新建的日程，会创建或选择新的 Collection，不会自动迁移旧 Collection 中已有数据。

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

离线优先架构：客户端 `LocalItemRepository` 直连本地 SQLite，所有 CRUD 即时完成。同步层通过 outbox push / cursor pull 异步交换变更，确定性 LWW 冲突恢复。ICS 订阅由客户端直接执行 ETag/Last-Modified 条件请求，解析到只读 Collection 后通过同一同步协议交换。

---

## 📋 待办事项 / TODO

目标：普通用户下载 Release 安装包后即可使用本地功能；除可选的云同步服务部署外，不需要安装 Python、Flutter 或 Node.js，不需要编辑配置文件或设置环境变量。所有运行时配置都应能在 App 内完成。

完整实施顺序、任务状态和验收标准见 **[ROADMAP.md](ROADMAP.md)**。本节保留优先级摘要，具体状态以 Roadmap 为准。

当前已经具备的基础能力：同步与功能服务地址、各自令牌、设备 ID、默认 Collection、AI Provider/API Key、通知开关和桌面窗口参数可以在设置页维护；服务令牌和 AI Key 使用系统安全存储。下面只列尚未闭环的工作。

### P0：Release / 开箱即用阻塞项

| ID | 任务 | 当前缺口 | 完成标准 |
|---|---|---|---|
| P0.1 | **拆分服务配置并做能力发现（已完成）** | 同步与功能服务地址、令牌已分离；Core 支持可选鉴权 | 设置页检测健康、版本、能力和鉴权；订阅与远程 ICS 自动探测并按能力降级；本地 Core 可免 token |
| P0.2 | **自动生成并持久化设备身份（已完成）** | 首次启动生成并保存唯一 ID，同时迁移旧固定默认值 | 设置页提供可读设备名称；技术 ID 仅在高级区域复制或经确认后重建；旧 outbox 保持原 ID 并可继续上传 |
| P0.3 | **建立多平台 Release 流水线** | tag 工作流已定义；待配置签名 Secrets 并完成三平台首次真实 Runner/安装验证 | Git tag 自动产出 macOS 签名并公证的 DMG/PKG、Windows 签名安装包、Android release 签名 APK（AAB 可选），同时上传 SHA-256、版本说明和必要的调试符号；签名材料只存在 CI Secrets |
| P0.4 | **干净安装和覆盖升级验收** | 目前的运行说明面向开发环境，尚未证明安装包脱离源码配置可用 | 在全新 macOS、Windows、Android 环境验证：无需 `config/client.json`、Python、Flutter、Node 即可启动和本地使用；重启后设置仍在；覆盖升级不丢数据库、同步令牌和 AI Key；形成可重复的 smoke test 清单 |
| P0.5 | **收敛 Python Core 与客户端的运行时边界（客户端本地能力已完成）** | ICS 文件传输、网址订阅和基础中文规则解析已在 Flutter 本地完成；复杂自然语言规则仍需 AI Provider 或手动校对 | 安装包不需要手工启动 Python；本地功能有明确错误状态；Python Core 仅作为可选兼容 API |
| P0.6 | **验证 Release 环境下的安全存储** | 代码已使用 `flutter_secure_storage`，但缺少签名安装包中的 Keychain/Credential Manager/Android Keystore 端到端验收 | AI Key 和同步令牌可新增、替换、清除并在重启/升级后读取；不会写入 SQLite、JSON 备份、日志或崩溃报告；macOS entitlements、Windows 包身份和 Android 备份策略均通过真机验证 |

### P1：设置闭环与产品化

| ID | 任务 | 当前缺口 | 完成标准 |
|---|---|---|---|
| P1.1 | **首次启动向导与配置诊断** | 设置项虽已存在，但首次启动没有引导，保存后也缺少独立、清晰的连通性诊断 | 首次启动可选择“仅本地使用”或“连接已有服务”；同步和 AI Provider 均有“测试连接”；错误能区分 DNS、TLS、超时、401、版本/能力不兼容；诊断失败不影响本地数据 |
| P1.2 | **时区、语言和日期偏好改为运行时设置（进行中）** | 首次安装已默认跟随系统 locale/IANA 时区，时区、语言、每周起始日和 12/24 小时制均可在设置中覆盖并立即应用；仍需完成全部日期文案的统一验证 | 首次启动默认跟随系统，并允许在设置中覆盖时区、语言、每周起始日和 12/24 小时制；修改后日历、解析、提醒、Widget 和导入导出使用同一配置，已有 UTC 数据不被错误改写 |
| P1.3 | **隐藏技术性 Collection ID** | 用户需要理解并手填 Collection ID，同步设备之间还要保证完全相同 | 普通界面只选择默认日历；Collection ID 由 App 生成和维护；连接已有数据时通过服务端列表、邀请/配置码或导入选择，不要求复制内部 ID；保留高级查看和复制入口 |
| P1.4 | **完善 AI Provider 配置向导** | Provider、URL、模型和参数主要依赖手填，模型不能自动获取，新配置不能在编辑弹窗内先测试 | 提供常见 OpenAI-compatible/Ollama 预设；可从 `/models` 或 Ollama tags 获取模型列表；编辑时可用尚未保存的 Key 测试；支持代理、超时和常用请求参数；提供 Key 的替换/清除状态但永不回显完整值 |
| P1.5 | **接入真实系统通知与权限设置** | 设置中已有通知开关，但运行时仍使用 InMemory adapter，用户不会收到系统通知 | macOS、Windows、Android 接入真实通知实现；设置页展示权限状态、申请/跳转系统设置、发送测试通知；提醒创建、修改、删除、重启恢复和时区变化均有自动化与真机测试 |
| P1.6 | **客户端备份、迁移和故障恢复** | 有手工 JSON 导出，但安装包升级前没有自动本地备份，也没有设置/数据库健康检查 | 数据库 schema 升级前创建可恢复备份；设置页支持查看备份、恢复和清理；启动迁移失败时保留原库并给出恢复入口；非敏感设置可单独导入导出，secret 和设备 ID 默认排除 |
| P1.7 | **应用内版本与更新入口** | 用户只能自行查看 GitHub Release，不知道当前版本是否过期 | “关于”页显示版本、构建号、平台和数据 schema；可检查 GitHub Release、打开对应安装包并展示更新说明；后续可按平台增加签名校验后的自动更新，且不绕过系统安全机制 |
| P1.8 | **统一应用身份与安装元数据** | macOS/Windows/Android 仍有 `easy_calendar`、模板注释和不一致的产品元数据 | 固定应用名、bundle/application ID、发布者、图标、版本规则和安装路径；Windows 卸载项、macOS About/签名信息、Android 应用标签一致；升级不会因标识变化创建第二份数据目录 |
| P1.9 | **补齐客户端 CI 质量门禁** | CI 未运行 Flutter analyze/test，也没有原生构建检查 | PR 必须通过 Flutter analyze/test、Python tests、Worker tests；至少编译 macOS、Windows、Android release；对首次启动、设置持久化、设备 ID 唯一性、能力发现和安全存储增加覆盖 |

### 待修复 / Known Issues

| # | 问题 | 说明 | 优先级 |
|---|------|------|--------|
| 1 | **Parser 覆盖有限** | 复杂时间范围、自然语言时长、重复规则需补充 fixture | 中 |
| 2 | **服务端自动备份未接入** | `auto_backup_before_migrate` 仍待实现；这是云端部署任务，不阻塞纯本地安装包 | 低 |
| 3 | **标签可复用** | 编辑标签时需手动输入，应列出已有标签供直接选择，避免重复和不一致 | 中 |

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
