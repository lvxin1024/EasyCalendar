# 产品文档中心

产品正式名称是 `EasyCalendar`。当前仓库目录和远程仓库路径仍是 `text2calendar`，它最初是一个“文字转日历”的 Python 原型；路径将在远程仓库完成改名后单独迁移。

命名决定和迁移边界见 [命名方案](./naming.md)。

## 文档规则

- **当前实现**：代码现在已经能做什么，必须以仓库现状为准。
- **目标契约**：未来客户端、同步服务和扩展实现必须遵守的稳定边界。
- **任务**：尚未实现的工作，必须有依赖、验收条件和独立提交边界。
- 所有时间使用 ISO 8601；API 字段使用 `snake_case`。
- 核心模型属于 domain 层；解析器、导入器、AI 和 UI 不得反向污染核心模型。
- 项目主要服务一个人，不设计组织、成员、角色、协作编辑和计费系统。

## 文档索引

| 文档 | 唯一职责 |
| --- | --- |
| [product-requirements.md](./product-requirements.md) | 产品范围、用户流程、非目标和验收标准 |
| [architecture.md](./architecture.md) | 当前原型、目标分层、部署拓扑和依赖方向 |
| [data-model.md](./data-model.md) | Item、Candidate、Collection、Subscription 和同步实体 |
| [sync-and-api.md](./sync-and-api.md) | HTTP API、同步协议、错误、认证和幂等性 |
| [extension-contracts.md](./extension-contracts.md) | Parser、Importer、AI、Repository、通知和 Widget 扩展接口 |
| [configuration.md](./configuration.md) | 用户可编辑的配置文件、配置键和敏感信息边界 |
| [deployment.md](./deployment.md) | Cloudflare 一站式部署、Docker 备选和升级回滚 |
| [roadmap.md](./roadmap.md) | 按依赖排序的任务、每步验收和 commit 边界 |
| [implementation-status.md](./implementation-status.md) | 当前代码盘点、已知缺陷和文档与实现的差距 |
| [development.md](./development.md) | 本地开发、测试、提交和扩展开发约定 |
| [naming.md](./naming.md) | 产品命名候选、推荐和改名迁移步骤 |
| [client.md](./client.md) | Flutter 客户端结构、配置、本地数据和平台验证状态 |

## 产品定位

一个可以单机使用、也可以连接自己的同步服务的个人日程和 Due 工具：

1. 日程和 Due 在本地数据库中统一保存。
2. 离线时仍然可以创建、编辑、完成和删除。
3. 用户确认前，规则解析器或 AI 只产生候选项，不直接写入正式数据。
4. 外部 ICS 订阅只读导入到独立 Collection。
5. 同步服务只保存一个自托管实例的数据，不承担复杂账号系统。
6. 所有部署参数集中在 `config/`，用户不需要改源码。

## 当前阶段

本仓库包含 Python/FastAPI 核心和 Flutter 客户端实现：

- 规则解析器已经可以输出 `CandidateItem`，并保留旧的 `events` 兼容视图。
- `Item` 领域模型、SQLite Repository、正式 CRUD、候选确认、提醒协调和 JSON/ICS transfer 已实现。
- 正式 `/v1/items`、`/v1/assistant`、`/v1/import`、`/v1/export` 已提供；历史 `/api/v1` 保留兼容。
- `client/` 已实现离线 SQLite CRUD 和核心页面；本机无 Flutter SDK，三平台 runner/build 验收状态见 `client.md`。
- 核心与可选 provider 依赖已分层锁定，`scripts/test.sh` 可在隔离环境运行离线测试。
- Cloudflare/Docker 同步服务和一站式部署仍是目标能力。

完整差距见 [implementation-status.md](./implementation-status.md)，实施顺序见 [roadmap.md](./roadmap.md)。
