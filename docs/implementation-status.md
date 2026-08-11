# 实现状态与差距

本文只描述当前仓库真实状态，不把规划中的 Flutter、Cloudflare 或 Widget 当成已经存在的实现。

## 已有实现

| 能力 | 当前位置 | 状态 |
| --- | --- | --- |
| 中文规则日期和时间提取 | `src/parser/date_extractor.py` | 原型可用，规则覆盖有限 |
| 事件类型、地点、参与人、优先级识别 | `src/parser/event_detector.py` | 原型可用，需继续补充测试 |
| Item / CandidateItem 领域模型 | `src/domain/models.py` | 已有确认转换、时区、版本和软删除约束 |
| Collection / Subscription / SyncChange / Outbox | `src/domain/models.py` | 已有状态转换、严格 JSON round-trip 和 SQLite 持久化 |
| SQLite Repository | `src/storage/` | migration、事务、savepoint、乐观锁、软删除查询、outbox 和 cursor 已实现 |
| Item Service | `src/application/item_service.py` | CRUD、恢复、Task 完成、outbox、持久化幂等和 cursor 分页已实现 |
| Candidate Service | `src/application/candidate_service.py` | 候选提取、持久化预览、拒绝审计和确认编排已实现 |
| Reminder Service | `src/application/reminder_service.py` | 相对/绝对提醒计算、持久化调度状态、改期取消、失败重试和启动恢复已实现 |
| Notification adapter | `src/notification/` | 平台 port 已定义；`memory` adapter 可用于离线开发和测试，不发送系统通知 |
| 解析器输出候选项 | `src/parser/rule_adapter.py` | 规则 Parser 已适配 Candidate application port，并使用请求时区和参考时间 |
| 旧 CalendarEvent 兼容视图 | `src/parser/models.py` | 临时兼容层 |
| FastAPI 解析 API | `src/api/routes.py` | 仍是历史 `/api/v1` 业务接口 |
| FastAPI Item API | `src/api/item_routes.py` | 已提供正式 `/v1/items` CRUD、分页、过滤和统一错误格式 |
| FastAPI Candidate API | `src/api/assistant_routes.py` | 已提供 `/v1/assistant/extract`、查询、拒绝和 `/v1/items/confirm-candidate` |
| Health / Capabilities | `src/api/system_routes.py` | 已提供目标 `/v1` 系统端点 |
| iCal 内存客户端 | `src/calendar_client/ical_client.py` | 原型，缓存不持久化 |
| Google / Outlook 客户端 | `src/calendar_client/` | 代码存在，未经可靠集成验证 |
| 配置 | `config/loader.py` | YAML、secrets.env、环境覆盖和严格校验已接入 |
| 本地启动入口 | `run.py` | 从统一配置读取 host、port 和 debug |
| 测试与依赖 | `scripts/test.sh` | 核心、开发和可选 provider 依赖已分层锁定 |

## 尚未实现的目标能力

- 单实例 Bearer token 鉴权。
- Cloudflare Worker、D1 migrations、push/pull 同步。
- ICS URL 订阅、ETag、RRULE 和只读 Collection。
- Flutter Android/macOS/Windows 客户端。
- Android、macOS、Windows 的真实系统通知 adapter 和 macOS WidgetKit。
- AI Provider 抽象、结构化输出校验和提醒建议。
- Web 或 Flutter 正式客户端。
- 配置文件驱动的一键 Cloudflare/Docker 部署。

## 目前必须注意的缺陷

1. `ICalClient` 主要使用内存缓存，进程重启后数据丢失。
2. `ICalClient.export_calendar()` 返回文件路径，而历史 API schema 把它当成 ICS 内容返回。
3. Google 客户端仍需真实 OAuth 流程验证，不能直接视为可用同步实现。
4. Outlook 客户端使用 client credentials 和 `/me` 路径的组合需要重新设计，不能直接视为可用同步实现。
5. SQLite 已有临时数据库和重启集成测试；同步和部署集成测试仍要随对应功能补充。
6. `deployment.auto_migrate` 已接入 Repository；`auto_backup_before_migrate` 要在备份/部署任务中接入，目前不能视为已有自动备份。

## 结论

正式 Item CRUD、Candidate 确认和可恢复本地提醒协调均已可用。下一步按路线图进入 T1.5 JSON/ICS 导入导出；真实系统通知由后续 Flutter 平台 adapter 实现，核心 Reminder 语义无需改动。
