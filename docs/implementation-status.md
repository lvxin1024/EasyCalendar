# 实现状态与差距

本文只描述当前仓库真实状态，不把规划中的 Cloudflare、系统通知或 Widget 当成已经存在的实现。

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
| Import/Export Service | `src/application/import_export_service.py` | JSON 全量备份恢复、ICS Event 导入导出、预览、重复检测、幂等提交和整批事务已实现 |
| Flutter 客户端 | `client/` | 离线 CRUD、outbox/cursor 同步、安全 token、网络恢复、确定性 LWW、墓碑和可查询冲突历史已实现；三平台 runner/lockfile、analyzer 和单测已验收，原生 build 待平台工具链 |
| Cloudflare 同步服务 | `server/` | Worker health/capabilities、Bearer 鉴权、D1 migration、双重幂等 push、cursor pull、确定性 LWW、墓碑和完整 winner/loser 冲突日志已实现 |
| Notification adapter | `src/notification/` | 平台 port 已定义；`memory` adapter 可用于离线开发和测试，不发送系统通知 |
| 解析器输出候选项 | `src/parser/rule_adapter.py` | 规则 Parser 已适配 Candidate application port，并使用请求时区和参考时间 |
| FastAPI Item API | `src/api/item_routes.py` | 已提供正式 `/v1/items` CRUD、分页、过滤和统一错误格式 |
| FastAPI Candidate API | `src/api/assistant_routes.py` | 已提供 `/v1/assistant/extract`、查询、拒绝和 `/v1/items/confirm-candidate` |
| FastAPI transfer API | `src/api/import_export_routes.py` | 已提供 `/v1/import` 和 `/v1/export`，支持 JSON/ICS、scope 和统一错误格式 |
| Health / Capabilities | `src/api/system_routes.py` | 已提供目标 `/v1` 系统端点 |
| 配置 | `config/loader.py` | YAML、secrets.env、环境覆盖和严格校验已接入 |
| 本地启动入口 | `run.py` | 从统一配置读取 host、port 和 debug |
| 测试与依赖 | `scripts/test.sh` | 单一命令安装锁定依赖并运行全部离线 Python 测试 |

## 已移除的 legacy

| 已删除内容 | 原因 | 正式替代或后续任务 |
| --- | --- | --- |
| `CalendarEvent` 和 Parser `events` 视图 | 与 Candidate 确认流程重复，允许绕过正式模型 | Parser 只返回 `CandidateItem` |
| `/api/v1` routes 和 schemas | 直接实例化旧模型和 provider，不遵守 application 边界 | 当前客户端只调用正式 `/v1` API |
| `src/calendar_client/` | 内存持久化、吞异常、认证流程和接口设计均不可靠 | T6.1 Importer SDK、T6.2 外部适配器重写 |
| provider requirements 和 provider 配置占位 | 没有正式消费者，却暗示功能可用 | 对应 adapter 实现时再引入最小配置和依赖 |
| `src/utils/date_utils.py` | 全仓无消费者，与 domain/parser 时间逻辑重复 | 需要共享时间能力时在明确层级重新设计 |

## 尚未实现的目标能力

- ICS URL 订阅、ETag、RRULE 和只读 Collection。
- Flutter 端 JSON/ICS transfer adapter 和真实平台通知 adapter。
- Android、macOS、Windows 的真实系统通知 adapter 和 macOS WidgetKit。
- AI Provider 抽象、结构化输出校验和提醒建议。
- Cloudflare 备份/回滚和 Docker 一键部署。

## 目前必须注意的缺陷

1. 规则 Parser 覆盖仍有限，复杂时间范围、自然语言时长和重复规则需要继续补充 fixture。
2. SQLite 已有临时数据库和重启集成测试；同步已有真实 in-memory SQLite/D1 集成测试，部署集成测试仍要随对应功能补充。
3. `deployment.auto_migrate` 已接入 Repository；`auto_backup_before_migrate` 要在备份/部署任务中接入，目前不能视为已有自动备份。
4. 当前机器有 Flutter 3.44.9，但没有 Android SDK、完整 Xcode/CocoaPods；Windows build 也必须在 Windows host 执行，因此三平台原生离线启动尚未全部验收。

## 结论

正式 Item CRUD、Candidate 确认、可恢复本地提醒协调、事务化 JSON/ICS transfer、Flutter 离线 CRUD，以及 T2 的 Worker/D1 与客户端同步、冲突恢复均已落地。下一项产品功能是 T3.1 Subscription 与只读 Collection；T1.6 的三平台原生启动验收作为环境任务保留。
