# 实现状态与差距

本文只描述当前仓库真实状态，不把规划中的 Flutter、Cloudflare 或 Widget 当成已经存在的实现。

## 已有实现

| 能力 | 当前位置 | 状态 |
| --- | --- | --- |
| 中文规则日期和时间提取 | `src/parser/date_extractor.py` | 原型可用，规则覆盖有限 |
| 事件类型、地点、参与人、优先级识别 | `src/parser/event_detector.py` | 原型可用，需继续补充测试 |
| CandidateItem / Item 基础模型 | `src/domain/models.py` | 已有基础模型，尚未持久化 |
| 解析器输出候选项 | `src/parser/rule_parser.py` | 已完成初步分离 |
| 旧 CalendarEvent 兼容视图 | `src/parser/models.py` | 临时兼容层 |
| FastAPI 解析 API | `src/api/routes.py` | 仍是历史 `/api/v1` 接口 |
| iCal 内存客户端 | `src/calendar_client/ical_client.py` | 原型，缓存不持久化 |
| Google / Outlook 客户端 | `src/calendar_client/` | 代码存在，未经可靠集成验证 |
| 静态 Web 页面 | `public/index.html` | 历史演示页面，不是目标客户端 |
| 配置 | `config/settings.py` | 当前主要读取环境变量 |
| 部署脚本 | `deploy.sh` | 主要是 GitHub 推送辅助，不是一键产品部署 |

## 尚未实现的目标能力

- SQLite schema、Repository、事务和 outbox。
- 正式 Item CRUD、Candidate confirmation 和 Due 完成接口。
- 单实例 Bearer token 鉴权。
- Cloudflare Worker、D1 migrations、push/pull 同步。
- ICS URL 订阅、ETag、RRULE 和只读 Collection。
- Flutter Android/macOS/Windows 客户端。
- 本地通知和 macOS WidgetKit。
- AI Provider 抽象、结构化输出校验和提醒建议。
- 配置文件驱动的一键 Cloudflare/Docker 部署。

## 目前必须注意的缺陷

1. 当前 API 在模块加载时直接导入 Google、Outlook 客户端；缺少可选依赖时，连纯解析 API 也可能无法启动。
2. `ICalClient` 主要使用内存缓存，进程重启后数据丢失。
3. `ICalClient.export_calendar()` 返回文件路径，而历史 API schema 把它当成 ICS 内容返回。
4. Google 客户端的认证刷新代码仍有未显式导入的引用风险。
5. Outlook 客户端使用 client credentials 和 `/me` 路径的组合需要重新设计，不能直接视为可用同步实现。
6. 当前 CORS 允许所有来源，正式自托管必须由配置限制。
7. `deploy.sh` 会修改 Git remote 和 Git user 配置，不应继续作为产品部署入口。
8. 当前完整测试环境缺少部分 requirements 依赖，测试基线需要先修复。

## 结论

当前代码适合作为 Parser/Calendar provider 原型，不足以作为“日程与 Due 应用”发布。下一步应先完成 T0.3、T0.4 和 T1.1，再把 API 从历史事件接口迁移到 Item 服务；不要先接 AI、Widget 或第三方 OAuth。
