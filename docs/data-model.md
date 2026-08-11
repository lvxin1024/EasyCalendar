# 数据模型

## 1. 通用约定

- 所有 ID 由创建方生成，使用 UUID 或带随机性的 ULID；不能依赖数据库自增 ID。
- API 和 JSON 使用 ISO 8601 字符串；内部实现可以使用语言原生 datetime。
- 时间必须带时区；没有时区的用户输入使用 `app.timezone`。
- 每个可同步实体都有 `created_at`、`updated_at`、`deleted_at?`、`version`。
- 删除使用软删除。实体从默认查询隐藏，但墓碑要保留到同步和备份策略允许清理。
- `updated_at` 相等时使用 `version`，仍相等时使用稳定 ID 作为确定性 tie-breaker。
- 用户自定义字段放 `metadata`，核心查询不能依赖未知 metadata 键。

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

Candidate 是解析阶段对象，不是存储对象：

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

`temp_id` 只在一次解析响应中使用。候选项被接受后，客户端可修改字段，再调用 `ConfirmCandidate` 生成新的正式 `id`。候选项被拒绝或请求过期时直接丢弃。

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

`mode=relative` 使用 `minutes_before`，`mode=absolute` 使用 `remind_at`。客户端负责根据时区计算下一次通知。

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
  "created_at": "2026-08-11T08:00:00Z",
  "updated_at": "2026-08-11T08:00:00Z",
  "version": 1
}
```

`kind` 为 `local`、`subscription` 或 `external`。`readonly=true` 时，来源导入器是唯一更新者。

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
  "created_at": "2026-08-11T08:00:00Z",
  "updated_at": "2026-08-11T08:00:00Z",
  "version": 1
}
```

URL 必须经过 SSRF 校验；禁止访问本机、私网、云平台 metadata 地址和未经配置允许的协议。

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

本地 `outbox` 额外保存 `created_at`、`retry_count`、`last_error`、`sent_at`。`change_id` 是幂等键，服务端必须记录已处理 ID。

## 8. SQLite 表

第一版建议：

```text
collections
items
reminders
subscriptions
outbox
sync_state
sync_conflicts
ai_extraction_history
```

外部事项的稳定键建议为 `(subscription_id, provider, external_id, recurrence_instance)`，避免重复刷新产生重复 Item。
