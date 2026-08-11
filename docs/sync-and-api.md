# HTTP API 与同步协议

## 1. API 约定

- 当前和目标前缀均为 `/v1`。
- 请求和响应使用 JSON，时间使用带时区的 ISO 8601。
- 写操作使用 `Idempotency-Key`，查询使用 cursor 分页。
- 错误使用统一结构，不直接把第三方 SDK 异常返回给客户端。
- 所有需要读取或修改用户数据的接口都要求单实例 Bearer token。

## 2. 认证

请求头：

```http
Authorization: Bearer <ADMIN_TOKEN>
Content-Type: application/json
X-Request-Id: optional-client-id
```

第一版没有用户登录和多用户身份。`ADMIN_TOKEN` 是一个自托管实例的访问凭据，客户端本地安全存储。后续若需要设备撤销，再新增设备 token，不改变 Item API。

公开接口：

- `GET /v1/health`
- `GET /v1/capabilities`，只返回非敏感能力和版本信息

其他接口默认 401。token 比较使用常量时间算法；日志只记录 token 指纹的前缀或哈希，不能记录原文。

## 3. 端点总览

| 资源 | 读 | 写/命令 |
| --- | --- | --- |
| health/capabilities | `GET /health`, `GET /capabilities` | 无 |
| items | `GET /items`, `GET /items/{id}` | `POST /items`, `PATCH/DELETE /items/{id}`, `POST /items/{id}/complete` |
| collections | `GET /collections`, `GET /collections/{id}` | `POST /collections`, `PATCH/DELETE /collections/{id}` |
| assistant | `POST /assistant/extract` | `POST /items/confirm-candidate`, `POST /assistant/extractions/{id}/reject` |
| subscriptions | `GET /subscriptions`, `GET /subscriptions/{id}` | `POST /subscriptions`, `PATCH/DELETE /subscriptions/{id}`, `POST /subscriptions/{id}/refresh` |
| sync | `GET /sync/pull` | `POST /sync/push` |
| transfer | `GET /export` | `POST /import` |

## 4. 通用响应和错误

成功响应直接返回资源，列表统一使用：

```json
{
  "data": [],
  "next_cursor": null,
  "has_more": false
}
```

错误响应：

```json
{
  "error": {
    "code": "validation_error",
    "message": "end_at cannot be before start_at",
    "details": {"field": "end_at"},
    "request_id": "req_01"
  }
}
```

错误码：

| HTTP | code | 说明 |
| --- | --- | --- |
| 400 | `validation_error` | 字段或业务约束错误 |
| 401 | `unauthorized` | token 缺失或错误 |
| 403 | `readonly_collection` | 试图修改订阅 Collection |
| 404 | `not_found` | 资源不存在或已不可见 |
| 409 | `version_conflict` | expected version 不匹配 |
| 409 | `idempotency_conflict` | 同一 key 对应不同请求 |
| 413 | `payload_too_large` | 超过 body、批量或文本限制 |
| 422 | `provider_invalid_output` | Parser/AI 输出无法校验 |
| 429 | `rate_limited` | 请求或 provider 限流 |
| 502 | `upstream_error` | ICS、AI 或外部 provider 失败 |
| 503 | `service_unavailable` | 服务未配置或暂时不可用 |

## 5. Health 和 Capabilities

### `GET /v1/health`

不需要 token。用于部署 smoke test，不检查外部服务是否可用：

```json
{
  "status": "ok",
  "service": "easycalendar",
  "version": "0.1.0",
  "schema_version": 1
}
```

### `GET /v1/capabilities`

`features` 表示当前代码已经实现的能力，`configured` 表示配置文件希望启用的能力。配置已开启但代码尚未实现时，两者可以不同；客户端必须以 `features` 为可调用依据。响应不泄露 URL、token、API key：

```json
{
  "api_version": "v1",
  "features": {
    "parser": true,
    "items": true,
    "sync": false,
    "ics_subscriptions": false,
    "assistant": true,
    "local_reminders": true,
    "json_backup": true,
    "ics_transfer": true,
    "widget_snapshot": false
  },
  "configured": {
    "sync": false,
    "ics_subscriptions": true,
    "assistant": false,
    "local_reminders": false,
    "widget_snapshot": false
  },
  "providers": {
    "parser": ["rules.zh_cn"],
    "ai": [],
    "notification": ["memory"]
  }
}
```

## 6. Items

### `GET /v1/items`

查询参数：

```text
collection_id     可选
type              event | task | note
status            todo | done | cancelled
from              时间范围起点
to                时间范围终点
include_deleted   默认 false
cursor            默认空
limit             默认 50，最大 200
```

Event 按 `start_at` 排序，Task 按 `due_at` 排序；无时间事项排在最后。响应使用 `data`、`next_cursor` 和 `has_more`。

### `POST /v1/items`

需要 `Idempotency-Key`。请求是完整 Item 的可写字段，服务端生成或接受客户端生成的全局 ID：

```json
{
  "id": "item_01",
  "collection_id": "collection_local",
  "type": "task",
  "title": "提交设计稿",
  "due_at": "2026-08-14T18:00:00+08:00",
  "priority": 3,
  "tags": ["工作"],
  "source": "local"
}
```

服务端返回完整 Item，`version=1`，并在同一个事务中写入 outbox/change log。重复同一 key 和同一 body 返回原响应。

### `GET /v1/items/{item_id}`

返回完整 Item，包括 reminders、source_ref 和 version。

### `PATCH /v1/items/{item_id}`

请求：

```json
{
  "expected_version": 2,
  "patch": {
    "title": "提交最终设计稿",
    "due_at": "2026-08-14T20:00:00+08:00"
  }
}
```

服务端检查 `expected_version`。冲突返回 409，并附当前版本摘要；客户端同步流程可按冲突策略决定覆盖或放弃。版本成功递增并写 outbox。

### `DELETE /v1/items/{item_id}`

需要 `expected_version` 或 `If-Match`。只写 `deleted_at`、递增 version 并产生 delete change。重复删除是幂等的。

### `POST /v1/items/{item_id}/restore`

请求包含 `expected_version`。恢复墓碑、递增 version 并产生 update change；未删除 Item 重复恢复时直接返回当前资源。

### `POST /v1/items/{item_id}/complete`

Task 专用，使用 `Idempotency-Key`：

```json
{"expected_version": 2}
```

将 status 设为 `done`。已经是 `done` 时返回当前 Item，不重复产生业务副作用；完成 Event 返回 400。

当前本地实现把 `Idempotency-Key`、规范化请求哈希和完整响应保存到 SQLite。服务重启后的同请求重试仍返回原 Item；同一个 key 对应不同请求时返回 `idempotency_conflict`。

## 7. Collections

### `GET /v1/collections`

返回当前实例的 Collection 列表，包含 `readonly`、`kind` 和颜色。

### `GET /v1/collections/{collection_id}`

返回单个 Collection 和统计摘要，例如 Item 总数、未完成 Task 数和最近同步时间。

### `POST /v1/collections`

创建本地 Collection，需要 `Idempotency-Key`：

```json
{
  "name": "个人",
  "kind": "local",
  "color": "#2563EB"
}
```

### `PATCH /v1/collections/{collection_id}`

只能修改本地 Collection 的名称和颜色。订阅 Collection 的 readonly 属性不可通过此接口关闭。

### `DELETE /v1/collections/{collection_id}`

本地 Collection 使用软删除或迁移其中 Item；非空时默认拒绝，避免误删。订阅 Collection 必须先删除 Subscription。

## 8. Candidate 和 Assistant

### `POST /v1/assistant/extract`

该端点不要求幂等键；每次调用创建一个新的持久化 extraction 预览。请求：

```json
{
  "text": "下周二上午十点和 Alex 在公司讨论发布计划，周五前交设计稿。",
  "timezone": "Asia/Shanghai",
  "now": "2026-08-11T08:00:00+08:00",
  "parser": "auto"
}
```

响应只包含候选项：

```json
{
  "extraction_id": "extract_01",
  "parser_id": "rules.zh_cn",
  "candidates": [],
  "warnings": []
}
```

AI provider 返回非法结构时，接口返回 422 或回退到规则 Parser；绝不返回一个看似成功但没有校验的候选。

`GET /v1/assistant/extractions/{extraction_id}` 可在刷新页面或服务重启后恢复同一预览。

### `POST /v1/items/confirm-candidate`

这是可选的服务端确认接口。纯本地 App 可以直接在本地 Repository 执行同一用例；需要同步的客户端可以将确认后的 Item push 到服务端。

请求：

```json
{
  "extraction_id": "extract_01",
  "candidate": {
    "temp_id": "cand_001",
    "type": "task",
    "title": "提交设计稿",
    "due_at": "2026-08-14T18:00:00+08:00",
    "confidence": 0.82
  },
  "edit": {
    "collection_id": "collection_local",
    "title": "提交最终设计稿",
    "priority": 3
  }
}
```

请求必须携带 `Idempotency-Key`。`candidate` 必须与 extraction 中持久化的原值完全一致，用户修改只放在 `edit`；这能区分原始解析结果和用户决策，防止客户端绕过审计。服务端生成正式 Item，并在一个事务中写 Item、提醒、outbox、确认决策和幂等结果。确认后的 Item 固定为 `source=ai`。

同一幂等键和同一请求返回原 Item；同一 Candidate 使用新幂等键重复相同决策也返回原 Item；不同编辑再次确认返回 `candidate_decision_conflict`。

### `POST /v1/assistant/extractions/{extraction_id}/reject`

可选的审计接口。拒绝只记录 extraction history，不产生 Item。若产品不需要服务端审计，可以只在客户端处理。

## 9. Subscriptions

### `GET /v1/subscriptions`

返回订阅配置、对应 Collection 和最近刷新状态；不返回认证 header 或敏感 URL query 中的 secret。

### `GET /v1/subscriptions/{subscription_id}`

返回单个订阅的配置和刷新状态，不返回抓取请求使用的秘密 header。

### `POST /v1/subscriptions`

需要 `Idempotency-Key`：

```json
{
  "type": "ics",
  "url": "https://example.com/calendar.ics",
  "title": "公开课程表"
}
```

服务端创建 readonly Collection 和 Subscription。URL 先经过协议、主机、DNS 和私网地址校验。

### `PATCH /v1/subscriptions/{subscription_id}`

支持 `title`、`enabled`、刷新频率覆盖。URL 修改应创建新的源哈希并触发一次可追踪刷新。

### `DELETE /v1/subscriptions/{subscription_id}`

停止刷新并软删除 Subscription。关联 Collection 和 Item 默认保留，用户可选择清理，避免订阅地址失效时数据突然消失。

### `POST /v1/subscriptions/{subscription_id}/refresh`

需要 `Idempotency-Key`，支持 `If-None-Match`。返回：

```json
{
  "status": "success",
  "created": 2,
  "updated": 4,
  "deleted": 0,
  "unchanged": 18,
  "last_success_at": "2026-08-11T08:00:00Z",
  "last_error": null
}
```

## 10. Sync

### `POST /v1/sync/push`

批量上限由 capabilities 声明。`change_id` 和 `Idempotency-Key` 都必须幂等：

```json
{
  "device_id": "macbook-01",
  "changes": [
    {
      "change_id": "chg_01",
      "entity_type": "item",
      "entity_id": "item_01",
      "operation": "update",
      "version": 3,
      "updated_at": "2026-08-11T08:00:00Z",
      "payload": {"title": "Project sync"}
    }
  ]
}
```

响应：

```json
{
  "accepted": ["chg_01"],
  "rejected": [],
  "conflicts": [],
  "server_cursor": "cur_124"
}
```

### `GET /v1/sync/pull?cursor=cur_123&limit=200`

返回服务端在 cursor 之后的有序变更：

```json
{
  "cursor": "cur_124",
  "has_more": false,
  "changes": []
}
```

客户端应用完整批次成功后再保存 cursor；应用失败时重试同一 cursor。

当前 Flutter T1.6 已在本地 mutation transaction 中写入带 `device_id`、entity、operation、version 和 payload 的 outbox，但尚未发送网络请求或保存 pull cursor。T2.3 在 Repository/transport 边界消费这些记录；设置页的 sync 开关当前只是持久化配置，不能当成同步已实现。

### 冲突策略

第一版按 `updated_at` 最后写入胜出；相同时间按 version，同一实体仍相等时按 `change_id`。删除参与比较。被覆盖的版本保留在 `sync_conflicts` 或服务端 change log，方便后续恢复。

## 11. Import 和 Export

### `POST /v1/import`

当前接口使用严格 JSON body，`content` 放 JSON 备份文本或 ICS 文本：

```json
{
  "format": "ics",
  "mode": "preview",
  "strategy": "merge",
  "content": "BEGIN:VCALENDAR...",
  "collection_id": "collection_local"
}
```

`mode=preview|commit`；commit 必须带 `Idempotency-Key`。JSON 支持 `strategy=merge|replace`，ICS 只支持 merge。`config.transfer.max_import_bytes` 限制 `content` 的 UTF-8 字节数。响应包含 `accepted`、`committed`、各资源的 `created/skipped/conflicts` 计数和逐条 issue：

```json
{
  "format": "json",
  "mode": "preview",
  "strategy": "merge",
  "accepted": false,
  "committed": false,
  "created": {},
  "skipped": {},
  "conflicts": {"items": 1},
  "issues": [
    {
      "resource_type": "items",
      "index": 0,
      "id": "item_01",
      "code": "conflict",
      "message": "An entity with this ID has different content"
    }
  ]
}
```

解析、domain 校验、引用校验和重复检测均先于写入；任一 issue 都会拒绝整批 commit。相同幂等键与相同请求返回原报告，相同键配不同内容返回 `idempotency_conflict`。

### `GET /v1/export?format=json|ics&scope=all|collection`

JSON 导出包含 schema_version、Collection、Item、Reminder、Subscription 和同步元数据；ICS 导出只包含可表达为 VEVENT 的 Event。导出不包含 token、API key 和 OAuth secret。

`scope=collection` 时必须传 `collection_id`。JSON 响应为 `application/json`，ICS 响应为 `text/calendar`。ICS 映射 SUMMARY、DESCRIPTION、LOCATION、DTSTART/DTEND、RRULE/EXDATE/RDATE、CATEGORIES 和 STATUS；全天 DATE 按 `app.timezone` 转为 Item，导出时恢复 DATE。导入来源记录为 `source=ics` 和稳定 UID/hash；同 UID 同内容跳过，同 UID 不同内容报告冲突。

本地 App 应优先实现本地导入导出；服务端接口用于远程备份和跨设备迁移。

## 12. 当前版本边界

早期 `/api/v1`、`CalendarEvent` 和 provider client 接口已删除，不属于受支持契约。当前客户端只使用本文列出的 `/v1` 端点；未来破坏性变更按 `/v2` 和迁移周期规则处理。
