# 扩展接口

扩展接口的目标是：新增来源、解析器或 AI Provider 时，不修改 Item 表、不修改核心状态机、不让具体 SDK 渗透到 domain 层。

下面使用接近 TypeScript 的伪接口描述跨客户端和服务端共享的契约；Python 原型可以用 `Protocol` 实现同样的边界。

## 1. Parser

```ts
interface Parser {
  id: string;
  version: string;
  parse(input: string, context: ExtractContext): Promise<ParseResult>;
}

interface ParseResult {
  candidates: CandidateItem[];
  confidence: number;
  parser_id: string;
  source_text: string;
  warnings: string[];
}

interface ExtractContext {
  now: string;
  timezone: string;
  locale: string;
  default_collection_id?: string;
}
```

Parser 只能产生候选项。它不能访问 Repository，不能调用 `create_item`，不能发送通知。

## 2. AiProvider

```ts
interface AiProvider {
  id: string;
  model: string;
  capabilities(): ProviderCapabilities;
  extractItems(input: string, context: ExtractContext): Promise<ParseResult>;
}
```

实现要求：

- 请求和响应必须有超时、最大输入长度和重试上限。
- 输出先经过 JSON schema 和业务校验，再转换成 Candidate。
- Provider 失败时返回结构化错误，不影响本地规则 Parser。
- API key 不能出现在日志、Candidate reasoning 或错误 detail 中。
- 不允许 Provider 直接写数据库。

## 3. Importer

```ts
interface Importer {
  id: string;
  version: string;
  source_type: "ics" | "google" | "microsoft" | "lark" | "markdown" | "plugin";
  validate(config: unknown): ValidationResult;
  preview(input: ImportInput): Promise<ImportPreview>;
  import(input: ImportInput): Promise<ImportResult>;
}

interface ImportResult {
  items: Item[];
  deleted_external_ids: string[];
  cursor?: string;
  warnings: string[];
}
```

Importer 要求：

- 每个 Item 写明 `source` 和 `source_ref`。
- 以稳定外部 ID 做 upsert，重复导入不能产生重复 Item。
- 订阅 Collection 的 Item 默认只读。
- 外部删除转换为软删除，不直接物理删除本地记录。
- 网络、解析和认证错误分开报告。

## 4. ItemRepository

```ts
interface ItemRepository {
  get(id: string): Promise<Item | null>;
  list(query: ItemQuery): Promise<Page<Item>>;
  create(item: Item, options: WriteOptions): Promise<Item>;
  update(id: string, patch: ItemPatch, options: WriteOptions): Promise<Item>;
  delete(id: string, options: WriteOptions): Promise<Item>;
  confirmCandidate(extractionId: string, candidate: CandidateItem, edit: CandidateEdit,
                   options: WriteOptions): Promise<Item>;
}
```

Repository 只负责事务、版本和持久化，不负责 HTTP、UI 或第三方同步。所有写入必须同时更新 Item 和 outbox，使用同一个数据库事务。

当前 Python SQLite adapter 位于 `src/storage/`。它是 T1.1 的低层持久化接口，application service 在 T1.2 中负责把 patch/delete 等用例转换为 domain 状态变更：

```python
with repository.transaction() as tx:
    tx.update_item(item, expected_version=previous_version)
    tx.create_outbox_entry(outbox_entry)
```

- `SQLiteRepository.from_settings(settings)` 只读取 `storage.sqlite_path` 和 `deployment.auto_migrate`，不要求用户修改源码。
- `SQLiteSession` 只在 transaction 上下文内有效；异常默认回滚整个事务。
- Item 与 Reminder 的复合写入有内部 savepoint。调用方捕获单次写入错误后继续事务，也不会留下半条 Item。
- `VersionConflictError` 区分乐观锁冲突；缺失、重复 ID、外键错误和损坏数据使用独立错误类型，供 API 层稳定映射。
- Repository 不自动生成 `change_id` 或 `device_id`。这些是 T1.2 application service 的职责，但 Repository 保证 Item 和 outbox 可原子提交。

## 5. SyncTransport 和 SyncStore

```ts
interface SyncTransport {
  push(request: PushRequest): Promise<PushResponse>;
  pull(request: PullRequest): Promise<PullResponse>;
}

interface SyncStore {
  pendingChanges(limit: number): Promise<SyncChange[]>;
  markAccepted(changeIds: string[]): Promise<void>;
  recordFailure(changeId: string, error: SyncError): Promise<void>;
  applyRemote(changes: SyncChange[]): Promise<ApplyResult>;
  cursor(): Promise<string | null>;
  saveCursor(cursor: string): Promise<void>;
}
```

应用远端变更前必须检查 `updated_at`、`version` 和删除墓碑。不能先更新 cursor 再写本地数据库。

## 6. NotificationScheduler

```ts
interface NotificationScheduler {
  schedule(request: NotificationRequest): Promise<string>;
  cancel(platformScheduleId: string): Promise<void>;
}
```

`NotificationRequest.notification_id` 是稳定键，adapter 的 schedule 必须可安全重试并返回平台句柄。通知是 Item 的派生行为：application 层负责计算、重调度和恢复，adapter 只调用平台 API。调度失败只记录状态，不回滚 Item 保存。每个平台可以有自己的 adapter，但不能改变 Reminder 语义。

## 7. WidgetSnapshotWriter

```ts
interface WidgetSnapshotWriter {
  write(snapshot: WidgetSnapshot): Promise<void>;
}

interface WidgetSnapshot {
  schema_version: number;
  generated_at: string;
  timezone: string;
  items: WidgetItem[];
}
```

快照必须是完整可替换文件，写入使用临时文件加原子 rename。Widget 不读取 SQLite，不访问网络，不保存编辑状态。

## 8. 扩展注册

每个扩展通过 manifest 声明：

```json
{
  "id": "parser.rules.zh_cn",
  "kind": "parser",
  "version": "1.0.0",
  "contract_version": "1",
  "config_schema": {},
  "capabilities": ["event", "task", "zh-CN"]
}
```

注册表只允许启用配置中列出的扩展。扩展加载失败时，核心服务应继续启动，并在 capabilities 中标记不可用原因。
