# 实施路线图

任务按依赖排序。每个任务都应形成一个可运行、可测试、可回滚的独立功能。按照当前协作约定：完成一个任务后单独 commit，汇报改动和测试，等待确认后再开始下一任务。

## 0. 基础整理

### T0.1 产品命名和配置契约

- 状态：本次文档任务。
- 内容：确定产品名；建立 `config/app.yaml`、`config/secrets.env` 和示例文件的规则。
- 验收：文档中所有用户需要修改的值都能在配置矩阵中找到；源码中没有要求用户手改的常量。

### T0.2 稳定领域模型

- 状态：已完成；commit `8d35665` 建立基础模型，当前任务补全同步实体、状态转换和序列化。
- 内容：补齐 Collection、Subscription、Outbox、同步变更、软删除和序列化校验。
- 验收：模型单测覆盖状态转换、时间约束、版本号、候选确认和 JSON round-trip。

### T0.3 配置加载和能力发现

- 状态：已完成。
- 依赖：T0.1。
- 内容：统一读取 `config/app.yaml` 和秘密文件；启动时校验；实现 `/v1/health` 和 `/v1/capabilities`。
- 验收：配置缺失时给出明确字段错误；无 AI 配置也能启动；服务端不需要改源码。

### T0.4 测试和依赖基线

- 状态：已完成。
- 内容：锁定 Python/Node/Flutter 版本策略；隔离核心运行依赖；建立单测、API 测试和集成测试命令。
- 验收：干净环境可以一条命令安装依赖并运行测试；测试不依赖真实 Google、Microsoft 或 AI 账户。

### T0.5 Legacy 原型清理

- 状态：已完成。
- 依赖：T0.2、T0.3、T1.2、T1.5。
- 内容：删除 `CalendarEvent`、旧 `/api/v1`、内存日历客户端、无消费者配置和 provider 依赖；Parser 固定为 Candidate-only contract。
- 验收：正式 `/v1`、JSON/ICS transfer 和启动流程通过全部离线测试；仓库不再导入或宣传已删除原型。

## 1. 本地优先 MVP

### T1.1 SQLite schema 和本地 Repository

- 状态：已完成。
- 依赖：T0.2、T0.3。
- 内容：版本化 migration；`items`、`collections`、`reminders`、`subscriptions`、`outbox`、`sync_state` 表；Repository 提供事务、查询、乐观锁和配置驱动的自动迁移。
- 验收：创建、更新、软删除、恢复查询和版本递增有单测；进程重启后数据仍在。

### T1.2 Item Service 和正式 CRUD API

- 状态：已完成。
- 依赖：T1.1。
- 内容：统一 Event/Task CRUD；完成 Task 的幂等命令；持久化幂等记录；cursor 分页、过滤和统一错误格式。
- 验收：正式 Item 的所有变更都写入 outbox；候选项不能直接绕过 Service 写库。

### T1.3 Candidate confirmation

- 状态：已完成。
- 依赖：T0.2、T1.1、T1.2。
- 内容：候选预览、修改、确认、拒绝；确认时生成正式 ID、审计 metadata 和 outbox。
- 验收：确认一次生成一个 Item；重复请求使用幂等键返回相同结果；拒绝不写 Item。

### T1.4 本地提醒

- 状态：已完成。
- 依赖：T1.2。
- 内容：提醒计算、时区处理、启停和平台适配接口。
- 验收：修改时间后旧提醒被取消；重启后提醒可恢复；通知失败不影响 Item 保存。

### T1.5 JSON/ICS 导入导出

- 状态：已完成。
- 依赖：T1.1、T1.2。
- 内容：全量 JSON 备份恢复；Event 的 ICS 导入导出；导入预览和重复检测。
- 验收：导出后重新导入数据等价；导入错误逐条报告，不使整个事务进入半成功状态。

### T1.6 Flutter 客户端骨架

- 状态：代码、三平台 runner、依赖解析、analyzer 和单测已完成；Android/macOS/Windows 原生构建启动仍待对应完整工具链验收。
- 依赖：T1.2。
- 内容：今日视图、列表视图、Due 过滤、编辑表单、设置页和本地 Repository 适配。
- 验收：Android、macOS、Windows 至少能离线启动并完成核心增删改查。

## 2. 自托管同步

### T2.1 Worker/D1 服务端骨架

- 状态：已完成。
- 依赖：T0.3、T1.2。
- 内容：Cloudflare Worker、D1 migrations、单实例 token、配置校验和错误格式。
- 验收：`setup` 命令可创建数据库并部署；错误 token 返回 401；健康检查无需 token。

### T2.2 Push / Pull 协议

- 状态：已完成。
- 依赖：T2.1、T1.1。
- 内容：change envelope、cursor、批量限制、幂等 change_id、应用结果。
- 验收：重复 push 不重复写入；pull cursor 可恢复；服务端重启不丢变更。

### T2.3 客户端 outbox 同步器

- 状态：已完成。
- 依赖：T2.2。
- 内容：重试、退避、失败状态、网络恢复触发、push 后清理和 pull 应用。
- 验收：断网创建、联网后自动同步；永久错误不会无限快速重试。

### T2.4 冲突和恢复

- 状态：已完成。
- 依赖：T2.3。
- 内容：按 `updated_at` 最后写入胜出；保留冲突记录；删除墓碑和版本检查。
- 验收：双设备并发编辑有确定结果；被覆盖版本可在日志中找到。

## 3. ICS 订阅

### T3.1 Subscription 和只读 Collection

- 状态：已完成；SubscriptionService、只读边界和 `/v1/collections`、`/v1/subscriptions` 已接入。
- 依赖：T1.2、T2.1。
- 内容：订阅 CRUD、URL 校验、启停和权限边界。
- 验收：订阅 Item 不能被普通编辑接口修改；关闭订阅后不再刷新。

### T3.2 抓取、ETag 和源哈希

- 状态：已完成；条件抓取、超时重试、响应大小限制、ETag/Last-Modified、源哈希和抓取审计已接入。
- 依赖：T3.1。
- 内容：超时、重试、ETag、Last-Modified、错误状态和审计日志。
- 验收：无变化源不产生重复变更；失败状态可查询；恶意 URL 按 SSRF 规则拒绝。

### T3.3 RRULE 和外部 ID 同步

- 状态：已完成；RRULE/EXDATE/RDATE 展开、订阅 UID 映射、远端删除和稳定刷新已接入。
- 依赖：T3.2、T0.2。
- 内容：RRULE、EXDATE、时区、UID 映射、远端删除。
- 验收：常见重复日历在时间范围查询中正确展开；刷新多次结果稳定。

## 4. Widget

### T4.1 Widget snapshot writer

- 状态：已完成；本地文件快照、原子替换、空快照和 Item 变更刷新已接入。
- 依赖：T1.2、T1.6。
- 内容：今日 Event、近期 Event、Due 快照和版本字段。
- 验收：主 App 更新后写出合法 JSON；没有数据时也有合法空快照。

### T4.2 macOS WidgetKit

- 状态：已完成；App Group、Widget timeline、快照错误占位和 `easycalendar://` 点击跳转已接入。
- 依赖：T4.1。
- 内容：App Group、Widget timeline、点击跳转和错误占位。
- 验收：离线时显示最近一次快照；快照损坏不导致 Widget 崩溃。

## 5. AI 助手

### T5.1 Provider 抽象和结构化输出校验

- 依赖：T0.2、T1.3。
- 内容：OpenAI-compatible、Ollama、本地规则 Provider；JSON schema 校验；超时和重试。
- 验收：Provider 可替换；无 key 时核心功能不受影响；非法 JSON 不写正式 Item。

### T5.2 候选预览和提醒建议

- 依赖：T5.1、T1.3。
- 内容：长文本多候选、引用文本范围、置信度、提醒建议和用户编辑。
- 验收：一次输入可生成 Event 和 Task；用户确认前没有正式写入。

## 6. 外部日历和插件

### T6.1 Importer SDK

- 依赖：T0.2、T3.3。
- 内容：Importer manifest、能力声明、来源映射和测试 fixture。
- 验收：新增 importer 不修改 Item 表和核心 Service。

### T6.2 Google/Microsoft/飞书适配

- 依赖：T6.1、T0.3。
- 内容：OAuth 或用户配置、最小权限、token 加密和外部 ID 映射。
- 验收：外部错误可重试；撤销授权后本地数据不丢；敏感凭据不进日志。

## 7. 暂缓任务

- 多用户账号和组织权限。
- 协作编辑和实时冲突 UI。
- 计费、插件市场和服务端统一通知。
- Windows 官方 Widget。

## 依赖总览

```text
T0.1 -> T0.3 -> T2.1 -> T2.2 -> T2.3 -> T2.4
T0.2 -> T1.1 -> T1.2 -> T1.3 -> T1.6
T1.2 -> T1.4 -> T4.1 -> T4.2
T1.2 -> T1.5
T1.2 -> T3.1 -> T3.2 -> T3.3 -> T6.1 -> T6.2
T1.3 -> T5.1 -> T5.2
T0.4 与所有阶段并行，但在发布前必须完成
```
