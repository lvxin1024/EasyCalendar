# EasyCalendar

EasyCalendar 是一个本地优先、可自托管的个人日程与 Due 管理工具。仓库包含 Python/FastAPI 核心、SQLite 正式数据层、Flutter 离线客户端，以及 Cloudflare Worker/D1 服务端骨架；push/pull 同步仍按路线图实施。

## 当前能力

- 使用本地规则把中文文本解析为 `CandidateItem`，核心流程不依赖 AI。
- 通过 `config/app.yaml`、`config/secrets.env` 和环境变量统一配置。
- 提供正式 `/v1` Item/Candidate API、JSON/ICS 导入导出和 health/capabilities。
- Flutter 客户端包含今日、全部、Due、编辑、设置和 SQLite 离线 CRUD；三平台构建状态见 `docs/client.md`。
- Cloudflare Worker 已提供公开 health/capabilities、单实例 Bearer 鉴权、D1 migration 和配置驱动的部署入口。
- 外部日历接入将在 Importer SDK 完成后按统一契约重新实现；仓库不保留未经验证的 provider 原型。

真实实现状态见 [docs/implementation-status.md](docs/implementation-status.md)。

## 本地启动

要求 Python 3.11 或更高版本，推荐使用 `.python-version` 中的 Python 3.13。

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
cp config/app.example.yaml config/app.yaml
.venv/bin/python run.py
```

默认地址为 `http://localhost:8000`，OpenAPI 文档位于 `http://localhost:8000/docs`。不复制 `config/app.yaml` 也可以使用安全的本地默认值启动；需要调整端口、时区或功能开关时只修改配置文件。

## 运行测试

一条命令会创建隔离的 `.venv-test`、安装锁定依赖并运行全部离线测试：

```bash
./scripts/test.sh
```

测试不访问真实 Google、Microsoft 或 AI 账户。

## 解析示例

```bash
.venv/bin/python examples/simple_example.py
```

```python
from src.parser.rule_parser import RuleParser

result = RuleParser().parse("明天上午9点开会讨论项目进度")
for candidate in result.candidates:
    print(candidate.title, candidate.start_at, candidate.confidence)
```

## Flutter 客户端

Flutter 固定为 `3.44.9`；首次运行会生成 Android/macOS/Windows runner、解析依赖并执行检查：

```bash
./scripts/setup-client.sh
./scripts/run-client.sh
```

客户端配置集中在未提交的 `config/client.json`，setup 会从示例创建。脚本会自动寻找 PATH 或 `~/flutter/bin/flutter`，并默认运行当前主机的桌面目标；Android 通过 `EASYCALENDAR_CLIENT_DEVICE` 指定设备。

## 产品文档

[docs/README.md](docs/README.md) 汇总产品需求、架构、配置、同步协议、部署目标和实施路线图。Cloudflare 基础部署入口已实现，push/pull、订阅、备份/回滚和 Docker 部署仍按路线图推进。

## License

MIT
