# 数据模型

## 1. 通用约定

- 所有 ID 由创建方生成，使用 UUID 或带随机性的 ULID；不能依赖数据库自增 ID。
- API 和 JSON 使用 ISO 8601 字符串；内部实现可以使用语言原生 datetime。
- 时间必须带时区；没有时区的用户输入使用 `app.timezone`。
- 每个可同步实体都有 `created_at`、`updated_at`、`deleted_at?`、`version`。
- 删除使用软删除。实体从默认查询隐藏，但墓碑要保留到同步和备份策略允许清理。
- `updated_at` 相等时使用 `version`；同一实体仍相等时使用稳定的 `change_id` 作为确定性 tie-breaker。
- 用户自定义字段放 `metadata`，核心查询不能依赖未知 metadata 键。
- 正式更新、首次软删除和首次恢复各递增一次 `version`；重复删除或重复恢复是幂等操作，不重复递增。
- `created_at`、`updated_at`、`deleted_at` 和同步时间必须带时区；解析器产生的无偏移日程时间在确认 Item 时按 `timezone` 转换。

领域对象的 `to_dict/from_dict` 使用本节展示的裸资源结构。用于备份、跨进程传输和 round-trip 的 `to_json/from_json` 使用严格 envelope：

```json
{
  "schema_version": 1,
  "model": "item",
  "data": {"id": "item_01J..."}
}
```

未知资源字段、未知 envelope 字段、错误 model 或不支持的 schema version 必须拒绝，不能静默丢弃。

## 2. Item

```json
{
  "id": "item_01J...",
  "collection_id": "collection_local",
  "type": "event",
  "title": "项目同步",
  "body": "讨论本周进度",
  "start_at": "2026-08-12T10:00:00+08:00",
  "end_at": "2026-08-12T10:30:00+08:00",
  "due_at": null,
  "timezone": "Asia/Shanghai",
  "all_day": false,
  "location": "会议室 A",
  "status": "todo",
  "priority": 2,
  "recurrence": null,
  "reminders": [],
  "tags": ["工作"],
  "source": "local",
  "source_ref": null,
  "metadata": {},
  "created_at": "2026-08-11T08:00:00Z",
  "updated_at": "2026-08-11T08:00:00Z",
  "deleted_at": null,
  "version": 1
}
```

字段：

| 字段 | 类型 | 规则 |
| --- | --- | --- |
| `id` | string | 全局唯一、创建后不变 |
| `collection_id` | string | 必须指向存在的 Collection |
| `type` | enum | `event`、`task`、`note` |
| `title` | string | 去除首尾空白后不能为空 |
| `body` | string? | 备注或正文 |
| `start_at` / `end_at` | datetime? | Event 使用；两者同时存在时 end 不早于 start |
| `due_at` | datetime? | Task 使用；不与 Event 时间范围混用 |
| `timezone` | string? | IANA 时区名 |
| `all_day` | boolean | 全天 Event 使用；全天 Task 仍以 due_at 语义为准 |
| `location` | string? | 地点或地址 |
| `status` | enum | `todo`、`done`、`cancelled` |
| `priority` | 0..3? | 0 未设置，1 低，2 普通，3 高 |
| `recurrence` | object? | iCalendar RRULE |
| `reminders` | Reminder[] | 只属于该 Item |
| `tags` | string[] | 去重，大小写策略由客户端统一 |
| `source` | enum | `local`、`ics`、`ai`、`google`、`microsoft`、`lark`、`plugin` |
| `source_ref` | object? | 外部 provider、ID、订阅和 etag |
| `metadata` | object | 扩展字段，不影响核心语义 |
| `version` | integer | 从 1 开始，每次正式变更递增 |

约束：

- `event` 至少应有 `start_at`；`end_at` 可以由 UI 给出默认时长。
- `task` 至少应有 `due_at` 或明确标记为无截止日期的待办。
- `source=ics` 的 Item 由订阅拥有，普通编辑接口只能读，刷新器负责更新。
- `deleted_at` 非空的 Item 不应出现在默认列表，但可被同步和管理员导出。

## 3. CandidateItem

Candidate 是解析阶段对象，不是正式 Item：

```json
{
  "temp_id": "cand_001",
  "type": "task",
  "title": "提交设计稿",
  "body": null,
  "start_at": null,
  "end_at": null,
  "due_at": "2026-08-14T18:00:00+08:00",
  "timezone": "Asia/Shanghai",
  "location": null,
  "attendees": [],
  "reminders": [
    {
      "mode": "relative",
      "minutes_before": 1440,
      "enabled": true,
      "reason": "截止日前一天提醒"
    }
  ],
  "confidence": 0.82,
  "reasoning": "deadline phrase and explicit date",
  "source_text_span": {"start": 18, "end": 24}
}
```

`temp_id` 只在一次 extraction 中唯一。当前本地服务会持久化 extraction 预览和拒绝状态，用于页面刷新、重启恢复和审计，但不会把 Candidate 写入 `items` 或 `outbox`。候选项被接受后，客户端把原 Candidate 和独立 `edit` 一起提交，`ConfirmCandidate` 生成新的正式 `id`；同一 `(extraction_id, temp_id)` 只能形成一个确认决策。

## 4. Reminder 和 RecurrenceRule

```json
{
  "id": "reminder_01",
  "item_id": "item_01",
  "mode": "relative",
  "minutes_before": 30,
  "remind_at": null,
  "enabled": true
}
```

`mode=relative` 使用 `minutes_before`：Event 从 `start_at` 回推，Task 从 `due_at` 回推；无时间 Note 不产生相对通知。`mode=absolute` 直接使用带时区的 `remind_at`。`enabled=false`、已过期、已完成、已取消或已删除的 Item 不调度。

平台调度是 Item 的派生状态，保存在 `reminder_schedules`：记录 `reminder_id`、`item_id`、Item 版本、UTC `fire_at`、`scheduled|failed`、平台句柄、最近错误和更新时间。它不进入 Item JSON 或同步 outbox；启动时根据正式 Item 强制重建。平台失败不能回滚 Item 保存。

```json
{
  "rrule": "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10",
  "exdates": ["2026-09-21T10:00:00+08:00"],
  "rdates": []
}
```

## 5. Collection

```json
{
  "id": "collection_local",
  "name": "我的日程",
  "kind": "local",
  "color": "#2563EB",
  "readonly": false,
  "metadata": {},
  "created_at": "2026-08-11T08:00:00Z",
  "updated_at": "2026-08-11T08:00:00Z",
  "deleted_at": null,
  "version": 1
}
```

`kind` 为 `local`、`subscription` 或 `external`。`kind=subscription` 强制 `readonly=true`，来源导入器是唯一更新者。颜色使用 `#RRGGBB`。

## 6. Subscription

```json
{
  "id": "sub_01",
  "collection_id": "collection_school",
  "type": "ics",
  "url": "https://example.com/calendar.ics",
  "title": "课程表",
  "enabled": true,
  "last_fetched_at": "2026-08-11T08:00:00Z",
  "last_success_at": "2026-08-11T08:00:00Z",
  "last_error": null,
  "etag": "abc123",
  "source_hash": "sha256:...",
  "metadata": {},
  "created_at": "2026-08-11T08:00:00Z",
  "updated_at": "2026-08-11T08:00:00Z",
  "deleted_at": null,
  "version": 1
}
```

URL 必须经过 SSRF 校验；禁止访问本机、私网、云平台 metadata 地址和未经配置允许的协议。

刷新失败更新 `last_fetched_at` 和 `last_error`，保留上一次 `last_success_at`；刷新成功同时更新 `last_fetched_at`、`last_success_at`、`etag` 和 `source_hash` 并清空错误。每次刷新结果都是一次正式状态变更。

## 7. SyncChange 和 Outbox

```json
{
  "change_id": "chg_01",
  "device_id": "macbook-01",
  "entity_type": "item",
  "entity_id": "item_01",
  "operation": "update",
  "version": 3,
  "updated_at": "2026-08-11T08:00:00Z",
  "payload": {"title": "更新后的标题"}
}
```

本地 `outbox` 额外保存 `created_at`、`retry_count`、`last_error`、`sent_at`。`change_id` 是幂等键，服务端必须记录已处理 ID。失败会递增 `retry_count`；首次成功设置 `sent_at` 并清空错误，重复标记成功保持幂等。

## 8. SQLite 表

当前版本化 SQLite migrations 已落地以下表：

```text
schema_migrations
collections
items
reminders
subscriptions
outbox
sync_state
idempotency_records
candidate_extractions
candidate_confirmations
reminder_schedules
```

存储约定：

- migration 只向前执行，文件名按连续版本编号；数据库记录已执行的版本和文件名，版本不兼容时拒绝启动。
- `collections`、`items`、`subscriptions` 和 `outbox` 同时保存核心查询列与严格 `payload_json`。查询不需要扫描 JSON，完整资源仍按 domain contract 还原。
- Reminder 独立存放并保留列表位置；创建或更新 Item 时与 Item 主记录在同一个 savepoint 中替换。
- 可同步实体写入使用 `expected_version` 乐观检查；待写实体必须正好是 `expected_version + 1`。
- 本地 `create` 只接受 `version=1` 且未删除的新实体；高版本备份恢复和远端应用使用后续独立接口，不能绕过创建语义。
- 每次写入前重新执行严格 domain 校验，防止可变对象在构造后被改成非法状态并污染数据库。
- 默认查询排除 `deleted_at` 非空记录，显式 `include_deleted` 才返回墓碑。
- 查询时间索引统一保存 UTC，domain payload 保留原始时区偏移。
- `sync_state` 保存 JSON 值，`remote_cursor` 是当前同步 cursor 的固定键。
- `idempotency_records` 按 `(scope, key)` 保存请求哈希和严格 Item 响应；同 key 不同请求拒绝，同请求在进程重启后仍返回原结果。
- migration 003 的 `candidate_extractions` 保存原文、Parser 标识、严格 Candidate JSON、warning 和拒绝审计；它不属于正式 Item 查询。
- `candidate_confirmations` 以 `(extraction_id, temp_id)` 为主键，记录唯一 Item、规范化请求哈希和确认时间；Item、outbox、确认和幂等记录在一个事务中提交。
- migration 004 的 `reminder_schedules` 保存可重建的派生平台状态，不直接外键到会被 Item 更新替换的 Reminder 行；改期或禁用后仍能找到并取消旧平台句柄。

`sync_conflicts` 以及外部事项稳定键 `(subscription_id, provider, external_id, recurrence_instance)` 随对应同步和订阅任务增加，不提前占位。
