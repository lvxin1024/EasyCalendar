# Flutter 客户端

## 1. 当前范围

`client/` 是 EasyCalendar 的本地优先 Flutter 客户端，目标平台为 Android、macOS 和 Windows。T1.6、T2.3 与 T2.4 已实现以下 Dart 代码：

- 响应式 NavigationRail / NavigationBar 外壳。
- 今日视图、全部事项搜索和类型过滤、Due 状态过滤。
- Event、Task/Due、Note 的创建和编辑表单。
- Event 全天/起止时间/地点，Task 截止时间/优先级，通用状态/标签/备注和提醒设置。
- Task 完成与恢复未完成、Item 软删除、空状态、加载状态和错误状态。
- SQLite 本地 Repository、乐观 version 检查和每次正式变更的 outbox 记录。
- API 地址、同步意向和通知意向的本地设置持久化。
- outbox 批量 push、cursor pull、失败分类、指数退避和网络恢复触发。
- 系统安全存储中的 Bearer token、同步状态和手动同步入口。
- 与 Worker 一致的确定性 LWW、删除墓碑、winner/loser 日志和冲突历史入口。

真实系统通知尚未接入；设置页的通知开关仍只是后续 adapter 的启用意向，不代表 T4 已完成。

## 2. 代码边界

```text
client/lib/
  config/             # dart-define 配置读取
  domain/             # Flutter 侧 Item/Draft/Preference 值对象
  data/               # Repository 接口和 SQLite adapter
  application/        # 页面共享的状态与用例编排
  sync/               # HTTP transport、同步协调、网络监控和安全 token port
  features/           # today/items/due/editor/settings/shell
  widgets/            # 可复用事项行和空状态
  utils/              # 配置时区与日期显示
```

Widget 只调用 `ItemController`；Controller 只依赖 `ItemRepository`；SQLite、路径和 UUID 细节留在 `LocalItemRepository`。后续接 Drift 或服务端同步时，不应把 SQL 或 HTTP 调用放进页面。

## 3. 本地数据

客户端首次启动在平台 Application Support 目录创建 `easycalendar.sqlite3`，文件名可配置。schema 包含：

```text
collections
items
subscriptions
outbox
sync_state
sync_entity_heads
sync_conflicts
app_settings
```

每次 create/update/complete/delete 都在一个 SQLite transaction 中更新 Item 并追加 outbox。update/delete 使用 `id + version` 乐观条件；删除写 `deleted_at` 墓碑，不硬删除。outbox 保留 `device_id`、entity、operation、version、retry/error/sent 字段，payload 使用稳定 Item domain 字段而不是 SQLite 列快照。同步器先发送默认 Collection 和本地变更，成功后删除已接受记录；临时错误写入指数退避时间，永久错误停止快速重试。pull 的整页变更和新 cursor 在同一事务提交，失败时一起回滚。

Bearer token 不写 SQLite、JSON 配置或日志，而由 `flutter_secure_storage` 保存。Android 声明网络权限，macOS 声明网络 client 与 Keychain Sharing entitlement；Windows 使用插件提供的 Credential Locker adapter。

每个同步实体的当前 head 保存其完整 change envelope。远端与本地统一按 `updated_at`、`version`、`change_id` 比较；删除墓碑不特殊降级。冲突表保存完整 winner/loser 快照，设置页可打开“冲突历史”查看被覆盖版本。pull 中较旧的远端 change 不会覆盖排序胜出的未发送本地 head。

当前 Flutter schema 是 T1.6 所需的 Item 子集，并保留后续 migration 边界；Python 完整备份不能直接复制成客户端 SQLite 文件。跨实现迁移统一走 T1.5 JSON API，后续任务再为 Flutter 增加对应 transfer adapter。

## 4. 配置

首次执行 setup 会把 `config/client.example.json` 复制为未提交的 `config/client.json`。用户只修改后者：

| 键 | 用途 |
| --- | --- |
| `EASYCALENDAR_APP_NAME` | 客户端标题 |
| `EASYCALENDAR_LOCALE` | Material locale |
| `EASYCALENDAR_TIMEZONE` | IANA 时区；今日、Due 和编辑器按此解释 |
| `EASYCALENDAR_DEFAULT_COLLECTION_*` | 首次启动创建的本地 Collection |
| `EASYCALENDAR_DATABASE_NAME` | Application Support 下的 SQLite 文件名 |
| `EASYCALENDAR_DEVICE_ID` | 本地 outbox 的设备标识 |
| `EASYCALENDAR_API_URL` | 同步服务地址默认值 |
| `EASYCALENDAR_SYNC_ENABLED` | 同步启用意向默认值 |
| `EASYCALENDAR_SYNC_RETRY_LIMIT` | 临时错误转为永久失败前的最大尝试次数 |
| `EASYCALENDAR_NOTIFICATIONS_ENABLED` | 通知启用意向默认值 |

运行脚本通过 `--dart-define-from-file` 注入配置。设置页对 API URL、同步和通知的修改写入本地 `app_settings`，优先于构建默认值。

## 5. 初始化和运行

客户端固定 Flutter `3.44.9`，`.fvmrc` 和 setup 脚本使用同一版本：

```bash
./scripts/setup-client.sh
./scripts/run-client.sh
```

setup 在临时目录调用 `flutter create`，只复制缺失的 Android/macOS/Windows runner，不覆盖 `client/lib`；随后执行 `flutter pub get`、`flutter analyze` 和 `flutter test`。脚本优先使用 `FLUTTER_BIN`、PATH，最后尝试 `~/flutter/bin/flutter`。指定设备：

```bash
EASYCALENDAR_CLIENT_DEVICE=macos ./scripts/run-client.sh
```

未指定设备时，macOS/Windows 主机默认使用本机桌面目标；Android 设备通过环境变量传入。Web 不属于当前支持范围，运行脚本会拒绝 `chrome` 和 `web-server`，避免 native SQLite/path-provider 在浏览器中产生 `MissingPluginException`。

## 6. 当前验证状态

已使用 Flutter `3.44.9` 完成：

- 生成并纳入版本控制的 Android、macOS、Windows runner、`.metadata` 和 `pubspec.lock`。
- `flutter analyze`：0 issues。
- `flutter test`：覆盖内存 Repository 下的 CRUD、今日计算和 Due 完成，以及 HTTP envelope、重试/永久失败、网络恢复、SQLite 原子 pull/cursor、本地胜出保护和被覆盖版本恢复。
- `scripts/setup-client.sh` 完整执行通过；Web 目标拒绝测试返回预期错误。

原生构建探测结果：

- macOS：runner 已生成，但本机只有 Command Line Tools，没有完整 Xcode/CocoaPods，`xcodebuild` 不可用。
- Android：runner 已生成，但本机没有 Android SDK，无法产出 debug APK。
- Windows：runner 已生成；Flutter 只允许在 Windows host 上执行 Windows build。

因此 T1.6 的代码、runner、依赖解析、analyzer 和单测已验收；“三平台离线启动”仍需在对应平台工具链安装完成后验收，不能标记为全部完成。
