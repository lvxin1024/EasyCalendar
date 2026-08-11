# Flutter 客户端

## 1. 当前范围

`client/` 是 EasyCalendar 的本地优先 Flutter 客户端，目标平台为 Android、macOS 和 Windows。T1.6 已实现以下 Dart 代码：

- 响应式 NavigationRail / NavigationBar 外壳。
- 今日视图、全部事项搜索和类型过滤、Due 状态过滤。
- Event、Task/Due、Note 的创建和编辑表单。
- Event 全天/起止时间/地点，Task 截止时间/优先级，通用状态/标签/备注和提醒设置。
- Task 完成与恢复未完成、Item 软删除、空状态、加载状态和错误状态。
- SQLite 本地 Repository、乐观 version 检查和每次正式变更的 outbox 记录。
- API 地址、同步意向和通知意向的本地设置持久化。

同步传输、真实系统通知和远端 Collection 尚未接入；设置页当前保存的是这些后续 adapter 的配置和启用意向，不代表 T2/T4 已完成。

## 2. 代码边界

```text
client/lib/
  config/             # dart-define 配置读取
  domain/             # Flutter 侧 Item/Draft/Preference 值对象
  data/               # Repository 接口和 SQLite adapter
  application/        # 页面共享的状态与用例编排
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
outbox
app_settings
```

每次 create/update/complete/delete 都在一个 SQLite transaction 中更新 Item 并追加 outbox。update/delete 使用 `id + version` 乐观条件；删除写 `deleted_at` 墓碑，不硬删除。outbox 已保留 `device_id`、entity、operation、version、retry/error/sent 字段，payload 使用稳定 Item domain 字段而不是 SQLite 列快照。T2.3 在此基础上增加 transport 和 cursor，不重写 UI CRUD。

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
| `EASYCALENDAR_NOTIFICATIONS_ENABLED` | 通知启用意向默认值 |

运行脚本通过 `--dart-define-from-file` 注入配置。设置页对 API URL、同步和通知的修改写入本地 `app_settings`，优先于构建默认值。

## 5. 初始化和运行

客户端固定 Flutter `3.35.7`，`.fvmrc` 和 setup 脚本使用同一版本：

```bash
./scripts/setup-client.sh
./scripts/run-client.sh
```

setup 在临时目录调用 `flutter create`，只复制缺失的 Android/macOS/Windows runner，不覆盖 `client/lib`；随后执行 `flutter pub get`、`flutter analyze` 和 `flutter test`。指定设备：

```bash
EASYCALENDAR_CLIENT_DEVICE=macos ./scripts/run-client.sh
```

## 6. 当前验证状态

本次实现环境没有 `flutter`、`dart`、FVM、Android SDK 或现成 runner，因此不能声称 Android/macOS/Windows 已实际编译启动。已完成的验证是：

- Python 静态契约测试检查配置键、固定依赖、页面/Repository 文件和 outbox 语义。
- shell 脚本通过 `bash -n`，缺少 SDK 时返回明确错误。
- Dart 文件完成 delimiter 静态检查。
- `client/test/item_controller_test.dart` 已覆盖内存 Repository 下的 CRUD、今日计算和 Due 完成，但必须在安装指定 Flutter SDK 后由 setup 实际运行。

`pubspec.lock` 和平台 runner 由首次成功 setup 生成；在此之前，T1.6 的代码实现已完成，但路线图中“三平台离线启动”的构建验收仍是明确剩余项。
