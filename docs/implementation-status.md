# 实现状态与差距

本文只描述当前仓库真实状态，不把规划中的 Flutter、Cloudflare 或 Widget 当成已经存在的实现。

## 已有实现

| 能力 | 当前位置 | 状态 |
| --- | --- | --- |
| 中文规则日期和时间提取 | `src/parser/date_extractor.py` | 原型可用，规则覆盖有限 |
| 事件类型、地点、参与人、优先级识别 | `src/parser/event_detector.py` | 原型可用，需继续补充测试 |
| Item / CandidateItem 领域模型 | `src/domain/models.py` | 已有确认转换、时区、版本和软删除约束 |
| Collection / Subscription / SyncChange / Outbox | `src/domain/models.py` | 已有状态转换和严格 JSON round-trip，尚未持久化 |
| 解析器输出候选项 | `src/parser/rule_parser.py` | 已完成初步分离 |
| 旧 CalendarEvent 兼容视图 | `src/parser/models.py` | 临时兼容层 |
| FastAPI 解析 API | `src/api/routes.py` | 仍是历史 `/api/v1` 业务接口 |
| Health / Capabilities | `src/api/system_routes.py` | 已提供目标 `/v1` 系统端点 |
| iCal 内存客户端 | `src/calendar_client/ical_client.py` | 原型，缓存不持久化 |
| Google / Outlook 客户端 | `src/calendar_client/` | 代码存在，未经可靠集成验证 |
| 配置 | `config/loader.py` | YAML、secrets.env、环境覆盖和严格校验已接入 |
| 本地启动入口 | `run.py` | 从统一配置读取 host、port 和 debug |
| 测试与依赖 | `scripts/test.sh` | 核心、开发和可选 provider 依赖已分层锁定 |

## 尚未实现的目标能力

- SQLite schema、Repository、事务和 outbox。
- 正式 Item CRUD、Candidate confirmation 和 Due 完成接口。
- 单实例 Bearer token 鉴权。
- Cloudflare Worker、D1 migrations、push/pull 同步。
- ICS URL 订阅、ETag、RRULE 和只读 Collection。
- Flutter Android/macOS/Windows 客户端。
- 本地通知和 macOS WidgetKit。
- AI Provider 抽象、结构化输出校验和提醒建议。
- Web 或 Flutter 正式客户端。
- 配置文件驱动的一键 Cloudflare/Docker 部署。

## 目前必须注意的缺陷

1. `ICalClient` 主要使用内存缓存，进程重启后数据丢失。
2. `ICalClient.export_calendar()` 返回文件路径，而历史 API schema 把它当成 ICS 内容返回。
3. Google 客户端仍需真实 OAuth 流程验证，不能直接视为可用同步实现。
4. Outlook 客户端使用 client credentials 和 `/me` 路径的组合需要重新设计，不能直接视为可用同步实现。
5. 当前只有离线单测和 API 契约测试；SQLite、同步和部署集成测试要随对应功能补充。

## 结论

当前代码适合作为 Parser/Calendar provider 原型，不足以作为“日程与 Due 应用”发布。下一步应进入 T1.1 SQLite Repository，把现有领域契约落到事务、查询和 outbox 持久化；不要先接 AI、Widget 或第三方 OAuth。
