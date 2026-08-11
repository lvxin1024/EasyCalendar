# 技术架构

## 1. 架构结论

产品采用单用户、自托管、local-first 架构。客户端拥有本地数据的编辑体验；同步服务只保存该实例的 canonical copy 和变更日志。服务端不承担多租户、团队权限或实时协作。

当前仓库的 Python/FastAPI 代码是 Parser 和日历客户端原型。目标架构会保留可复用的 Parser 逻辑，但不能把现有 `CalendarEvent`、内存缓存或第三方客户端直接当成最终数据层。

## 2. 运行拓扑

```text
Android App       macOS App       Windows App
       \              |              /
        \       Flutter UI         /
         +-- Local SQLite/Drift --+
                    |
              Application services
        parser/importer/assistant adapters
                    |
       outbox + sync state + widget snapshot
                    |
          HTTPS Bearer token sync
                    |
       Cloudflare Worker + D1 (+ R2 backup)
                    |
          Cron -> ICS subscription refresh

macOS WidgetKit <- App Group <- local widget snapshot
```

Docker 版用一个 API 容器和 SQLite volume 替代 Worker/D1，接口和数据模型保持一致。Redis、Postgres 和服务端通知调度不是第一阶段依赖。

## 3. 分层

### Domain

拥有 `Item`、`CandidateItem`、`Collection`、`Subscription`、`Reminder`、`SyncChange` 等模型和不依赖平台的规则。

Domain 不能导入：FastAPI、Flutter、Cloudflare、SQLAlchemy/Drift、Google SDK、AI SDK。

### Application

拥有用例和事务边界：

- `CreateItem`、`UpdateItem`、`CompleteTask`、`DeleteItem`。
- `ConfirmCandidate`、`RejectCandidate`。
- `RefreshSubscription`。
- `PushChanges`、`PullChanges`。
- `ExportData`、`ImportData`。

Application 通过抽象接口调用存储、同步、通知、Importer 和 Provider。

当前 `src/application/item_service.py` 已实现正式 Item 创建、查询、修改、软删除、恢复、Task 完成和 Candidate 确认。`src/application/candidate_service.py` 负责提取预览、查询和拒绝。`src/application/import_export_service.py` 负责 JSON 备份恢复、ICS Event 映射、导入预览、重复检测和幂等提交。服务通过 Repository port 访问存储；跨资源导入在一个事务内写 Collection、Item/Reminder、Subscription、outbox 和 sync state，HTTP 和 SQLite 细节不进入 domain。数据库提交后，`ReminderService` 才协调平台通知，因此调度失败不会回滚 Item。

### Adapters

- API adapter：将 HTTP 请求映射到 application command/query。
- SQLite adapter：`src/storage/` 已实现本地 Repository、migration、outbox 和 sync cursor；D1 adapter 尚未实现。
- Parser/AI adapter：`RuleParserAdapter` 已实现规则解析 port，其他 provider 仍待实现。
- Notification adapter：`NotificationSchedulerPort` 定义稳定调度/取消边界；当前 `memory` adapter 只用于开发和测试，系统 adapter 由各客户端平台实现。
- ICS/Google/Microsoft adapter：输出带来源信息的 Item。
- Notification adapter：把 Reminder 转成平台通知。
- Widget adapter：把查询结果写成 snapshot。

### Client UI / Platform

Flutter 负责跨端 UI、本地数据库访问编排和设置。当前 `client/` 已按 `Widget -> ItemController -> ItemRepository -> LocalItemRepository` 落地，SQLite 支持离线 CRUD、乐观 version、软删除和 outbox。macOS WidgetKit、Android alarm、Windows toast 通过后续 platform adapter 接入。Widget 和通知都不能拥有第二份 Item 业务逻辑。

### SQLite 事务边界

- `SQLiteRepository` 拥有连接、migration 和线程互斥；`SQLiteSession` 只在一次显式 transaction 中有效。
- 每个直接 Repository 写方法自动开启事务；跨实体原子写入使用 `repository.transaction()`。
- Item 和 Reminder 的复合写入使用 savepoint，防止局部约束错误留下半次写入。
- application service 必须在一次 transaction 中完成 domain 实体和 outbox 写入，Repository 不负责生成业务 change。

## 4. 数据流

### 手动创建

```text
UI -> ItemService -> SQLite transaction
                    |- items
                    |- reminders
                    `- outbox(change)
```

### 文本解析

```text
text -> Parser/AiProvider -> candidate_extractions
                          -> user edits/rejects
                          -> ConfirmCandidate -> ItemService transaction
                                                |- Item + Reminder
                                                |- outbox
                                                |- confirmation decision
                                                `- idempotency record
```

候选预览可持久化用于刷新页面、审计和重启恢复，但没有正式 `id`、`version` 或 `collection_id`，不出现在 Item 查询和同步 outbox 中。确认请求必须引用持久化 extraction；用户修改通过独立 `edit` 传入，不能篡改原 Candidate。

### 本地提醒

```text
Item transaction commit
        -> ReminderService computes fire_at
        -> cancel stale platform schedule
        -> NotificationScheduler.schedule/cancel
        -> reminder_schedules records scheduled/failed state

process restart -> scan persisted Items -> force reconcile -> platform adapter
```

相对提醒以 Event `start_at` 或 Task `due_at` 为基准；绝对提醒直接使用 `remind_at`。禁用提醒、过去时间、已完成/取消/删除 Item 都不应保留平台调度。平台错误只更新派生失败状态，Item 和 outbox 已经提交。

### 远端同步

```text
outbox -> SyncTransport.push -> server apply idempotently
server changes -> SyncTransport.pull(cursor) -> conflict policy -> SQLite
```

### 备份与导入

```text
JSON/ICS -> parse + domain validation + reference validation
         -> preview duplicate/conflict report
         -> one SQLite transaction
            |- replace: clear restorable data, then restore original versions
            `- merge: insert missing entities or skip byte-equivalent entities
```

任何逐项错误或冲突都会拒绝整个提交。JSON 备份不包含 secret、Candidate 临时数据、幂等记录或可重建的提醒调度状态；ICS 只表达 Event，不作为完整备份格式。

## 5. 服务端职责

服务端只做以下事情：

- 校验单实例 Bearer token。
- 接收和保存 Item/Collection/Subscription 的增量变更。
- 通过 cursor 返回远端变更。
- 保存订阅配置并按 Cron 刷新公开 ICS。
- 可选代理 AI Provider，但不让 AI 绕过候选确认。
- 提供备份和能力发现信息。

服务端不做：

- 用户注册、组织、角色和权限矩阵。
- 客户端本地通知调度。
- 实时 WebSocket 协作。
- 依赖某个第三方 AI 或日历账号才能启动。

## 6. 扩展原则

### 稳定核心

所有来源最终转换为 `Item` 或 `CandidateItem`。Provider 的专有字段放入 `metadata`，来源身份放入 `source_ref`，不得在 `items` 表中为每个 provider 增加专有列。

### 可选依赖

Google、Microsoft、AI 和 Cloudflare SDK 必须延迟加载或作为独立 adapter。只启用本地规则 Parser 时，安装和启动不能要求第三方凭据。

### 版本化

- Domain JSON schema 有 `schema_version`。
- Domain JSON envelope 同时包含稳定 `model` 名，反序列化拒绝未知字段和错误版本。
- HTTP 接口有 `/v1` 前缀。
- Sync change 保留 `version` 和 `updated_at`。
- Plugin/Provider manifest 声明能力版本和兼容的 Item schema。

## 7. 当前仓库到目标架构的迁移

1. 把现有 Parser 输出固定为 Candidate contract。
2. 添加 SQLite Repository 和 application service。
3. 让 FastAPI 只调用 service，不直接创建 `CalendarEvent` 或 client。
4. 将 `src/calendar_client/` 重构为 Importer/Exporter adapter。
5. 新增 `server/` 和 `client/`，两者共享文档化 JSON contract，而不是共享 Python 实现。
6. 最后再接 AI、Widget 和 OAuth provider。
