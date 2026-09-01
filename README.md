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
  <a href="https://github.com/lvxin1024/EasyCalendar/actions"><img src="https://github.com/lvxin1024/EasyCalendar/actions/workflows/tests.yml/badge.svg" alt="Tests" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
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
- 💻 macOS / Windows / Android 三平台 Flutter 客户端
- 🔒 数据完全在你手里：本地 SQLite 存储，可选自托管同步服务
- 🤖 可选 AI 助手（OpenAI-compatible / DeepSeek / Ollama），确认后才写入正式日程
- 📡 支持 ICS 日历订阅（客户端本地条件抓取）
- 🌙 经期记录、每日症状和本地周期预测，可选跨设备同步

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
| 🤖 AI 助手 | OpenAI-compatible / DeepSeek / Ollama 多 Provider，候选预览确认后写入 |
| 📡 ICS 订阅 | 外部日历只读导入独立 Collection，ETag 条件抓取 |
| 📦 导入导出 | JSON 全量备份、ICS 文件导入，预览后提交 |
| 🗑️ 回收站 | 软删除恢复，乐观锁幂等保护 |
| 🔔 通知提醒 | 平台通知适配接口，提醒改期自动协调 |
| 🌙 经期跟踪 | 经期、流量、点滴出血和症状记录，本地预测默认不上传 |
| 🔄 自动同步 | 日程、日历、订阅和经期记录通过 outbox push / cursor pull 同步 |
| 🪟 桌面窗口 | macOS/Windows 透明度、置顶、点击穿透，桌面日历 overlay |
| 🧩 macOS Widget | App Group 离线 timeline，快照损坏容错 |

---

## 🚀 下载与使用 / Getting Started

普通用户只需下载对应平台的 [GitHub Release](https://github.com/lvxin1024/EasyCalendar/releases) 安装包，安装后选择“仅本地使用”即可进入 App。本地日历、Due、提醒、备份、ICS 导入导出、网址订阅和基础中文解析都在客户端内完成。

**使用安装包不需要 Python、Flutter、Node.js，也不需要修改配置文件或环境变量。** 设备 ID 会在首次启动时自动生成，其他运行时选项都可以在 App 设置中管理。

需要更强的自然语言理解时，在“设置 > AI Provider”中配置 OpenAI-compatible、DeepSeek 或 Ollama。App 会直接请求该 Provider，API Key 保存在系统安全存储中，不需要 Python Core 中转。

### 组件边界

| 组件 | 是否必需 | 说明 |
|---|---|---|
| **EasyCalendar App** | 是 | macOS / Windows / Android 客户端，内置 SQLite，离线可用 |
| **Cloud Sync** | 否 | Cloudflare Worker / D1 多设备同步服务 |
| **Python Compatibility API** | 否 | 面向开发者和第三方集成的参考 REST API，不在 App 主链路上 |

---

## ☁️ 可选：多设备同步

部署同步服务后，各客户端仍以本地 SQLite 为主，通过 Cloudflare Worker 交换 outbox 变更，D1 保存服务端变更日志和冲突记录。断网时可以继续使用，恢复网络后再同步。

```
┌──────────┐     ┌──────────────────┐     ┌──────────┐
│  macOS   │ ←→  │  Cloudflare       │ ←→  │  Windows │
│  Client  │     │  Worker + D1      │     │  Client  │
└──────────┘     └──────────────────┘     └──────────┘
```

Cloudflare Worker + D1 是当前唯一实现的多设备同步服务器。部署命令只需在一台开发电脑上执行，Worker 和数据库最终运行在你的 Cloudflare 账户中，不需要 VPS，也不要求这台电脑保持开机。

### 1. 准备账号、工具和同步地址

需要以下内容：

- Cloudflare 账号。免费套餐可以用于个人同步。
- Git 和 Node.js 22.x（与 `server/.nvmrc` 和 CI 一致，运行 `node --version` 检查）。
- 本仓库源码，以及一个最终提供给所有客户端使用的 HTTPS 地址。

同步地址有两种选择：

| 方案 | 示例 | 准备方式 |
|---|---|---|
| **workers.dev** | `https://my-easycalendar-server.<账户子域>.workers.dev` | 在 Cloudflare Dashboard 的 **Workers & Pages** 中先启用 workers.dev 子域。Worker 名固定为 `<instance_name>-server`。|
| **自定义域名** | `https://calendar.example.com` | 域名必须已接入同一个 Cloudflare 账号，建议使用没有现有 DNS/Worker 路由的独立子域。部署脚本会创建 Custom Domain 路由并由 Cloudflare 配置 HTTPS。|

使用 workers.dev 时，先在 Dashboard 中确认自己的“账户子域”，不要把示例里的 `<账户子域>` 原样写入配置。比如 `instance_name` 为 `my-easycalendar`，Worker 名就是 `my-easycalendar-server`，最终地址应为 `https://my-easycalendar-server.<账户子域>.workers.dev`。

克隆仓库并安装 Worker 依赖：

```bash
git clone https://github.com/lvxin1024/EasyCalendar.git
cd EasyCalendar
./scripts/setup.sh install
cd server
npx wrangler login
npx wrangler whoami
cd ..
```

Windows PowerShell 使用下面的等价命令：

```powershell
git clone https://github.com/lvxin1024/EasyCalendar.git
Set-Location EasyCalendar
npm --prefix server ci
Set-Location server
npx wrangler login
npx wrangler whoami
Set-Location ..
```

`wrangler login` 会打开浏览器。授权时应选择实际持有目标域名和 D1 数据库的 Cloudflare 账号；`wrangler whoami` 用于确认当前登录账号。

### 2. 创建部署配置

在仓库根目录复制本地配置模板。这两个目标文件已被 Git 忽略，不应提交：

```bash
cp config/app.example.yaml config/app.yaml
cp config/secrets.example.env config/secrets.env
```

PowerShell：

```powershell
Copy-Item config/app.example.yaml config/app.yaml
Copy-Item config/secrets.example.env config/secrets.env
```

编辑 `config/app.yaml`。模板默认是本地 Python API 配置，Cloudflare 同步必须至少改成下面这样：

```yaml
app:
  name: EasyCalendar
  instance_name: my-easycalendar
  timezone: Asia/Shanghai
  locale: zh-CN

server:
  mode: cloudflare
  public_url: https://my-easycalendar-server.<账户子域>.workers.dev
  cors_allowed_origins:
    - https://my-easycalendar-server.<账户子域>.workers.dev

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
  auto_backup_before_migrate: false
```

- `app.instance_name` 只能包含小写字母、数字和连字符，最长 63 个字符。它会生成 `<instance_name>-server` Worker 和 `<instance_name>-db` D1 数据库。
- `server.public_url` 必须与最终访问地址完全一致，使用 HTTPS，不能带路径、查询参数或末尾之外的内容。使用自定义域名时，把上面的 workers.dev 地址替换成自己的域名。
- `cors_allowed_origins` 不接受 `*`。原生 macOS、Windows、Android 客户端不依赖浏览器 CORS，目前可填写与 `public_url` 相同的 origin。
- `sync.pull_limit` 必须在 1-1000 之间，个人使用保留 `200` 即可。

### 3. 生成访问令牌

使用 Node.js 生成 32 字节随机令牌，macOS、Linux 和 Windows 都可执行：

```bash
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

把输出的 64 位十六进制字符串写入 `config/secrets.env`：

```dotenv
ADMIN_TOKEN=<上一步生成的 64 位十六进制字符串>
AI_API_KEY=
```

这个令牌等同于同步服务密码。不要提交、截图或发到 Issue；需要同步的设备使用同一个令牌。

### 4. 校验并部署

macOS / Linux：

```bash
./scripts/setup.sh validate --config config/app.yaml
./scripts/setup.sh --config config/app.yaml
```

Windows PowerShell：

```powershell
node server/scripts/setup.mjs validate --config config/app.yaml
node server/scripts/setup.mjs setup --config config/app.yaml
```

完整部署会按顺序执行以下操作：

1. 查找或创建 `<instance_name>-db` D1 数据库。
2. 生成本地 `server/.generated/wrangler.json`，绑定 D1 和域名。
3. 对远程 D1 执行尚未应用的 migrations。
4. 部署 `<instance_name>-server` Worker。
5. 把 `ADMIN_TOKEN` 写入 Cloudflare Worker Secret，不写入生成的 Wrangler 配置。
6. 请求 `<public_url>/v1/health`，确认服务与数据库 schema 版本兼容。

不要手工编辑 `server/wrangler.jsonc` 或 `server/.generated/wrangler.json`，它们分别用于本地开发和自动生成。以后配置变化时重新执行同一条 setup 命令即可。

### 5. 验证服务

浏览器打开下面的地址，无需令牌：

```text
https://你的同步域名/v1/health
```

正常响应类似：

```json
{"status":"ok","service":"easycalendar","version":"0.1.0","schema_version":4}
```

这里的 `version` 是同步 API 版本，不要求与客户端 Release 版本相同；部署脚本主要检查 `status` 和 `schema_version`。

经期同步要求客户端版本不低于 `0.1.3`，且服务端 `schema_version` 不低于 `4`。从旧版本升级时，必须先重新运行 setup 应用 `0004_cycle_sync.sql` 并部署 Worker，再让各设备执行“立即同步”；否则普通日程可能正常同步，但经期记录会被旧协议拒绝。

然后在 App 中使用“测试连接”。如果健康检查成功但测试连接返回 `401`，通常是客户端令牌与 `config/secrets.env` 中的 `ADMIN_TOKEN` 不一致。

### 6. 连接客户端

在每台设备打开“设置 > 连接”，填写并保存：

| 设置项 | 如何填写 | 示例 |
|---|---|---|
| **同步服务地址** | 所有设备填写同一个 Cloudflare Worker HTTPS 地址 | `https://calendar.example.com` |
| **同步服务令牌** | Cloudflare Worker 的 `ADMIN_TOKEN`；需要同步的设备填写同一个值 | 上面生成的 64 位字符串 |
| **设备名称** | 用于区分设备，可按习惯修改 | `工作电脑`、`手机` |
| **默认日历** | 从 App 中已有的可写日历中选择 | `我的日程` |
| **同步** | 打开开关，保存后点击“立即同步” | 开启 |

新设备需要连接已有同步日历时，先在原设备复制“日历配置码”，再在新设备选择“连接已有日历”并粘贴。Collection ID 由 App 自动维护，普通用户不需要填写；只在高级连接设置中提供查看和复制。

这些设置会持久化在当前安装中。同步令牌保存在系统安全存储中；“测试连接”会检查网络、TLS、鉴权、API 版本、同步能力和经期同步所需的 schema 版本，不会修改日历数据。设备 ID 会自动生成并长期保存，只应在复制安装、身份冲突或排查同步问题时使用高级设置中的“重建设备身份”。

推荐接入顺序：先在原设备完成一次“立即同步”，确认没有错误；再复制日历配置码到新设备，测试连接并同步。不要在两台设备上分别新建同名日历来代替“连接已有日历”，它们会被视为两个不同 Collection。

### 7. 更新、备份和令牌轮换

更新 Worker 时，拉取新代码、重新安装锁定依赖，然后再次运行 setup。已有 D1 数据库会复用，只应用新增 migration：

```bash
git pull --ff-only
./scripts/setup.sh install
./scripts/setup.sh --config config/app.yaml
```

PowerShell：

```powershell
git pull --ff-only
npm --prefix server ci
node server/scripts/setup.mjs setup --config config/app.yaml
```

部署前建议导出 D1 备份。先确保至少成功部署过一次，再从 `server/` 目录执行：

```bash
cd server
npx wrangler d1 export DB --remote --config .generated/wrangler.json --output ../easycalendar-d1-backup.sql
cd ..
```

当前部署脚本不会自动创建或恢复 D1 备份，`auto_backup_before_migrate` 不能代替上述手工导出。备份文件可能包含私人日程，不要提交到 Git。

轮换令牌时，生成新令牌并替换 `config/secrets.env` 中的 `ADMIN_TOKEN`，重新运行 setup，然后立即在所有客户端更新令牌。旧令牌在 Worker Secret 更新后会失效。

### 常见问题

| 现象 | 检查和处理 |
|---|---|
| `wrangler` 提示未登录或账号不对 | 在 `server/` 执行 `npx wrangler whoami`；必要时重新执行 `npx wrangler login` 并选择正确账号。|
| 部署完成但 health smoke test 失败 | 检查 `server.public_url` 是否与实际 workers.dev 子域或自定义域名完全一致，并直接访问 `/v1/health`。|
| 自定义域名无法创建 | 确认域名 Zone 在当前 Cloudflare 账号中且状态为 Active，并换用没有冲突 DNS 记录或 Worker 路由的子域。|
| App 测试连接返回 `401` | 重新输入 `ADMIN_TOKEN`，注意不要包含尖括号、引号、前后空格或换行。|
| D1 已创建但后续步骤失败 | 修正配置或网络后重新运行 setup；数据库创建和 migration 都可重复执行。|
| 换设备后出现两个同名日历 | 在新设备删除误建日历，再使用原设备生成的日历配置码选择“连接已有日历”。|

### Cloudflare 与已有服务器的分工

- **Cloudflare 账户**：配置和运行 Worker、D1、同步域名及 `ADMIN_TOKEN`，客户端同步地址指向这里。
- **已有远程服务器/VPS**：可选，只在需要 Python Compatibility API 时使用；它与 App 的本地功能和云同步链路都相互独立。
- **客户端设备**：各自保存本地 SQLite 数据；需要多设备同步时连接同一个 Worker，但使用各自唯一的设备 ID。

> 当前尚未实现 Docker Compose 一键部署、VPS 同步服务和自动 D1 备份/回滚。不要把 Python Compatibility API URL 填成同步服务地址。

---

## 🛠️ 开发者指南 / Development

### 从源码运行 App

Flutter 3.44.9 是开发环境依赖，不是普通用户的安装依赖。`setup-client.sh` 会校验 Flutter 版本并安装 Dart 包，但不会安装 Flutter SDK 或平台原生工具。

| 构建目标 | 额外开发依赖 |
|---|---|
| Android | JDK 17，以及 Flutter 3.44.9 所需的 Android SDK/NDK |
| macOS | macOS、Xcode 和 Xcode Command Line Tools |
| Windows | Windows、Visual Studio C++ Desktop 工具链和 ATL/MFC 组件 |

```bash
git clone https://github.com/lvxin1024/EasyCalendar.git
cd EasyCalendar
./scripts/setup-client.sh
./scripts/run-client.sh
```

也可以进入 `client/` 目录直接执行 `flutter pub get` 和 `flutter run -d <device-id>`。`config/client.json` 只用于定制首次启动默认值；运行时配置仍以 App 设置为准。

### Python Compatibility API（可选）

仓库根目录的 `src/` 保留了规则解析、导入导出和 AI 助手等 REST API 的参考实现，可用于第三方客户端、兼容性测试或服务端扩展。它不承担多设备同步，也不是 EasyCalendar App 的运行依赖。

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python run.py
# API: http://localhost:8000
# OpenAPI docs: http://localhost:8000/docs
```

不创建配置文件也可以以安全默认值启动。需要定制时再复制 `config/app.example.yaml` 和 `config/secrets.example.env`；不要提交实际密钥。如果对外网络暴露 Core，必须配置 `ADMIN_TOKEN` 和 HTTPS，并在 App 的可选“功能服务”中填写该地址，不要与同步服务地址混用。

### 发布维护

`main` 分支上的 Tests 通过只表示代码可构建，不会生成公开下载文件。只有推送与 `client/pubspec.yaml` 版本一致的 `vX.Y.Z` tag，GitHub Actions 的 **Client Release** 工作流才会构建三端安装包、创建 GitHub Release，并把文件上传到下载页。

#### 发布一个新版本

1. 修改 `client/pubspec.yaml` 中的版本：

   ```yaml
   version: 0.1.3+4
   ```

   `0.1.3` 是用户看到的版本号，`4` 是必须持续递增的构建号。已经存在的 tag 不能重复使用。

2. 提交版本变更并推送 `main`，等待 **Tests** 工作流全部通过：

   ```bash
   git add client/pubspec.yaml
   git commit -m "chore: release v0.1.3"
   git push origin main
   ```

3. 创建并推送与版本号完全一致的 tag。tag 不包含 `+4` 构建号：

   ```bash
   git tag -a v0.1.3 -m "EasyCalendar v0.1.3"
   git push origin v0.1.3
   ```

4. 打开仓库的 **Actions > Client Release** 查看构建。Android、Windows 和 macOS 全部成功后，`publish` job 会自动创建 Release；不要提前手工创建同名 Release。

5. 打开 [GitHub Releases](https://github.com/lvxin1024/EasyCalendar/releases) 检查安装说明和附件，再把这个页面发给用户。工作流会自动生成变更记录和 `SHA256SUMS.txt`。

如果 tag 与 `pubspec.yaml` 版本不一致，`version` job 会立即失败。修复发布问题时应提交修复并发布一个新的版本/tag，不要移动已经公开的 tag。

#### Release 中的文件

| 文件 | 用途 |
|---|---|
| `*-android.apk` | Android 用户直接下载安装。|
| `*-android.aab` | 上传 Google Play 等应用商店，不供普通用户直接安装。|
| `*-windows-x64-setup.exe` | Windows 安装器，普通用户优先下载。|
| `*-windows-x64-portable.zip` | Windows 免安装便携包。|
| `*-macos.dmg` | macOS 安装镜像。|
| `*-symbols.*` | 崩溃堆栈还原用的调试符号，只供维护者保存。|
| `SHA256SUMS.txt` | 下载文件的 SHA-256 校验值。|

没有配置任何签名 Secret 时，工作流仍能生成可下载的 Release 文件，文件名会包含 `unsigned`。这适合测试和自主分发；正式对公众长期发布时，应配置稳定签名，尤其不要用临时 Android key 发布需要后续覆盖升级的 APK。

#### 正式签名（可选）

签名材料在 GitHub 仓库的 **Settings > Secrets and variables > Actions** 中配置，只存 Actions Secrets，不写入仓库。每个平台要么配置完整一组，要么全部留空：

- Android：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。
- Windows：`WINDOWS_CERTIFICATE_PFX_BASE64`、`WINDOWS_CERTIFICATE_PASSWORD`。
- macOS：`MACOS_CERTIFICATE_P12_BASE64`、`MACOS_CERTIFICATE_PASSWORD`、`MACOS_SIGNING_IDENTITY`、`MACOS_APP_PROVISION_PROFILE_BASE64`、`MACOS_WIDGET_PROVISION_PROFILE_BASE64`、`APPLE_ID`、`APPLE_APP_PASSWORD`、`APPLE_TEAM_ID`。

#### 无正式签名材料的发布

- Android 的 4 个签名 Secrets 全部留空时，CI 使用一次性临时 key 生成 `EasyCalendar-<version>-unsigned-android.apk` 和 AAB。该 APK 可以侧载，但下一次使用不同临时 key 构建的 APK 无法覆盖升级，也不能作为稳定的应用商店发布密钥。
- macOS 的 8 个 Apple 签名 Secrets 全部留空时，CI 会移除无法授权 App Group 的 Widget，对主 App 执行 ad-hoc Release 签名，并产出 `EasyCalendar-<version>-unsigned-macos.dmg`。此产物不会公证，首次打开需在 Finder 中右键 App 选择“打开”，或在“系统设置 > 隐私与安全性”中选择“仍要打开”。
- Windows 的 `WINDOWS_CERTIFICATE_PFX_BASE64` 和 `WINDOWS_CERTIFICATE_PASSWORD` 都留空时，CI 会产出 `EasyCalendar-<version>-unsigned-windows-x64-setup.exe` 和对应便携包。SmartScreen 可能需要用户选择“更多信息 > 仍要运行”。
- 任一平台的签名 Secrets 不允许只配置一部分。CI 会在检测到不完整配置时失败，避免误发布看似已签名的产物。

unsigned/ad-hoc 产物仍然是优化后的 Release 构建，不是 Debug 构建。发布页会根据实际产物自动加入警告和首次打开方法，并提醒用户按 `SHA256SUMS.txt` 校验文件。

### 运行测试

```bash
./scripts/test.sh          # Python 离线测试
(cd client && flutter analyze --no-pub && flutter test --no-pub)
(cd server && npm run check) # TypeScript、Worker 和本地 D1 migration
```

---

## 🛠️ 技术实现 / Tech Stack

| 层 | 技术 |
|---|---|
| 客户端 | Flutter 3.44.9, Dart, SQLite (sqflite), platform channels |
| 可选兼容 API | Python 3.11+, FastAPI, SQLite, icalendar, python-dateutil |
| 同步服务 | TypeScript, Cloudflare Workers, D1, Hono, outbox/cursor 协议 |
| AI | OpenAI-compatible / DeepSeek / Ollama Provider, Candidate 确认流程 |
| 本地解析 | Flutter `LocalRuleParser`，不依赖 AI 或 Python |

离线优先架构：客户端 `LocalItemRepository` 直连本地 SQLite，所有 CRUD 即时完成。同步层通过 outbox push / cursor pull 异步交换变更，确定性 LWW 冲突恢复。ICS 订阅由客户端直接执行 ETag/Last-Modified 条件请求，解析到只读 Collection 后通过同一同步协议交换。



## 🤝 贡献 / Contributing

项目主要服务一个人，欢迎 Issue 和 PR。

- 提交前运行上面的 Python、Flutter 和 Worker 检查
- 每个功能独立 commit，不混合无关改动

> This project primarily serves a single user, but issues and PRs are welcome. Run tests before submitting, and keep commits focused.

---

## 📄 开源协议 / License

[MIT](LICENSE) © EasyCalendar

---

<p align="center">
  <sub>Made with ☕️ and 🗓️</sub>
</p>
