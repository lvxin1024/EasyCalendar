# 开发约定

## 仓库边界

目标目录分层如下；未实现目录可以先不存在，但新增代码应放在对应边界内：

```text
client/                 # Flutter Android/macOS/Windows 客户端
server/                 # Cloudflare Worker/Hono，未来新增
src/domain/             # Python 原型共享的领域模型
src/application/        # 用例、事务编排和 adapter ports
src/storage/            # SQLite Repository、migration 和持久化契约
src/parser/             # 规则 Parser 原型
src/notification/       # 平台通知 adapter；当前含开发用 memory 实现
src/api/                # 当前 FastAPI 原型 API
src/runtime.py          # 配置驱动的延迟依赖组装
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

## 工具链和依赖

- Python 最低支持 3.11，默认开发版本由根目录 `.python-version` 固定为 3.13；CI 同时验证 3.11 和 3.13。
- `requirements.txt` 只包含启动核心 API 所需的精确版本，包括正式 ICS transfer 使用的 `icalendar`。
- `requirements-dev.txt` 包含全部离线测试依赖；外部日历 adapter 在 T7 实现时建立各自明确的依赖边界。
- Node.js 在 Worker 代码进入仓库时固定 LTS 主版本并提交 lockfile；在此之前不维护空的 Node 工程。
- Flutter 客户端固定 `3.44.9`，版本写在 `client/.fvmrc`，setup 脚本从该文件读取并校验。runner 和 `pubspec.lock` 必须提交；analyzer/单测通过不等于平台原生构建通过。
- Worker 固定 Node.js 22，版本写在 `server/.nvmrc`，npm 依赖由 `server/package-lock.json` 精确锁定。
- 升级依赖必须单独提交并通过全部测试；业务功能提交不顺带放宽版本范围。

## 本地命令

```bash
./scripts/test.sh             # 隔离环境中的全部 Python 测试
python run.py                 # 从 config/ 读取设置并启动 API
./scripts/setup-client.sh     # 生成 runner、解析依赖、analyze 和 test
./scripts/run-client.sh       # 使用 config/client.json 运行 Flutter
./scripts/setup.sh install    # 安装锁定的 Worker/部署依赖
./scripts/setup.sh validate --config config/app.yaml
```

`scripts/test.sh` 默认使用 `.venv-test`，可以通过 `PYTHON` 选择解释器，通过 `EASYCALENDAR_TEST_VENV` 调整测试环境目录。脚本和 CI 不读取用户的第三方账户凭据。

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
5. Transfer 集成测试：临时 SQLite 间 JSON 等价恢复、ICS fixture、重复检测和失败批次回滚。
6. Sync 集成测试：双设备 outbox、cursor、冲突和重试。
7. 部署 smoke test：从空目录加载配置、启动、健康检查和迁移。

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
