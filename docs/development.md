# 开发约定

## 仓库边界

目标目录分层如下；未实现目录可以先不存在，但新增代码应放在对应边界内：

```text
client/                 # Flutter 客户端，未来新增
server/                 # Cloudflare Worker/Hono，未来新增
src/domain/             # Python 原型共享的领域模型
src/parser/             # 规则 Parser 原型
src/calendar_client/    # 历史日历 provider，逐步迁移为 importer
src/api/                # 当前 FastAPI 原型 API
config/                 # 用户配置和示例，不放业务逻辑
docs/                   # 产品和工程契约
tests/                  # 单测和集成测试
scripts/                # 可重复执行的安装、校验、部署脚本
```

依赖方向必须是：

```text
API/UI -> application service -> domain
                  ^
parser/importer/AI -+
storage/sync/notification 通过接口连接 application/domain
```

Domain 不得导入 FastAPI、Flutter、Cloudflare SDK、具体 AI SDK 或具体数据库驱动。

## 配置和秘密

- 用户修改 `config/app.yaml` 和未提交的 `config/secrets.env`，不改源码。
- `config/app.example.yaml` 必须与每个发布版本同步。
- 任何 token、API key、OAuth secret 不得进入 Git、日志、错误响应或测试 fixture。
- 测试使用 `config/test.yaml` 或内存依赖注入，不读取用户真实配置。

## 测试层级

1. Domain 单测：时间约束、状态、版本、候选确认。
2. Parser/Importer fixture 测试：输入固定，输出稳定。
3. Repository 集成测试：临时 SQLite，验证事务和重启恢复。
4. API 契约测试：请求、响应、错误、鉴权和幂等键。
5. Sync 集成测试：双设备 outbox、cursor、冲突和重试。
6. 部署 smoke test：从空目录加载配置、启动、健康检查和迁移。

单测不得要求网络。第三方集成测试必须显式使用环境变量启用。

## Commit 规则

- 一个用户可验收功能对应一个 commit。
- commit 前运行与功能匹配的最小测试和 `git diff --check`。
- commit 后汇报：做了什么、改了哪些文件、测试结果、剩余风险。
- 等产品负责人确认后再开始下一个功能。
- 不把工作区已有的无关修改混入当前 commit。

## API 兼容

- 新接口统一使用 `/v1`。
- 破坏性变更使用 `/v2`，旧版本至少保留一个迁移周期。
- 字段废弃先保留响应兼容，再在文档标记 `deprecated`。
- 所有写操作必须说明幂等策略和事务边界。
