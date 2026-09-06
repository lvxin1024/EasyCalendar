# EasyCalendar P2P 同步路线图

状态：实施中
分支：`feat/p2p-sync`
范围：保留现有 Cloudflare Worker/D1，同步新增无需用户部署服务的同步组模式。

## 当前实现状态

| 里程碑 | 状态 | 说明 |
|---|---|---|
| 1-4 | 已完成 | 模式配置、ECG1 同步码、authority schema/store |
| 5 | 已完成 | authority engine、LWW/幂等、三端星型模拟 |
| 6 | 已完成 | Rust transport-neutral bridge、帧/HMAC/错误码/生命周期 |
| 7 | 已完成 | Dart group peer、push/pull、`changesAvailable` 通知 |
| 8a | 已完成 | secure group profile store、创建/加入/导出流程 |
| 8b | 已完成 | 接入 endpoint ticket、selector、首次启动和设置页 UI |
| 9 | 已完成 | Android 前台 dataSync service；桌面退出语义和 iOS 限制文案 |
| 10 | 进行中 | Android/Windows/macOS native 构建与打包已接入；待 hosted CI 首次验证、真实端到端测试、运维和最终质量门禁 |

当前代码已经在 `main.dart` 中通过 `SyncTransportSelector` 接入 Iroh group peer，
Cloudflare HTTP transport 仍然保留。`IrohSyncGroupPeer` 负责认证、push/pull、
cursor 和通知；Rust crate 提供 endpoint/QUIC frame 的 FFI 边界。发布与 PR 工作流
已经接入 Android 四 ABI、Windows DLL 和 macOS 通用 dylib 的构建与产物断言；iOS
没有固定 Runner 和静态链接阶段，暂不宣称支持群组同步。首次 hosted CI 构建和真实
多设备端到端验证完成前，当前实现仍不能描述成已承诺 SLA 的公网同步服务。

## 1. 目标和非目标

### 目标

- 普通用户首次配置只需要创建或扫描一次同步码。
- 允许任意已安装设备创建同步组并成为主节点。
- 主节点保存权威 change log；从节点保留本地 SQLite 和 outbox。
- 本地变更写入成功后立即提交主节点；在线设备收到轻量通知后按 cursor 拉取。
- 支持跨公网 NAT 环境：优先端到端直连，失败时使用 Iroh relay 转发。
- 保留 Cloudflare 模式，不改变现有 HTTP push/pull 协议和配置方式。
- 主节点离线时不丢本地变更；恢复连接后按现有重试和 cursor 机制补齐。

### 非目标

- 第一版不做自动故障转移、自动选主或多主合并。
- 第一版不做纯全连接 Mesh 的逐设备 ACK；拓扑固定为一主多从。
- 不把日历数据上传到 EasyCalendar 项目方服务器。
- 不直接同步 SQLite 文件；同步单位仍然是现有 change JSON。
- 不把 iOS 普通后台运行承诺为 24 小时服务器。

## 2. 用户模式

`SyncMode` 只有三个值：

```text
local  仅本地
cloud  现有 Cloudflare Worker/D1
group  Iroh 同步组
```

当前首次启动和设置页提供：

- 仅本地使用
- 创建同步组
- 加入同步组
- 连接已有 Cloudflare 服务

群组入口会自动生成或恢复 endpoint 私钥和身份；主节点创建后展示可复制的
`ECG1-...` 同步码，从节点粘贴同步码即可完成注册。没有 native bridge 的安装包
会显示明确错误，但不会影响仅本地或 Cloudflare 模式。

已有 `apiUrl`、`syncEnabled`、Bearer token 和日历配置码保持兼容。同步组配置不复用 `apiUrl`，避免把 Iroh ticket 当成 URL 或把群组密钥混入普通设置导出。

## 3. 拓扑和生命周期

```text
                 ┌──────────────┐
                 │ 主节点       │
                 │ authority    │
                 └──────┬───────┘
          push / pull   │ changes_available
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   从节点 A        从节点 B        从节点 C
```

- 每个设备都有独立 Iroh Endpoint keypair。
- 同步组密钥只用于组认证和派生组 ID；设备私钥不离开设备。
- 主节点接受成员设备的 push、执行现有确定性 LWW 冲突规则、追加权威日志。
- 从节点只向主节点 push/pull，不互相写入。
- 主节点重启后从本地 authority store 恢复日志和成员表。
- 主节点离线期间，从节点继续本地 CRUD，并保留 outbox；重连后先 push 再 pull。

## 4. 同步码和安全边界

同步码使用版本化 canonical JSON，外层格式暂定：

```text
ECG1-<base64url(canonical-json)>.<base64url(sha256(payload))>
```

payload 字段：

```json
{
  "protocol": 1,
  "group_id": "sha256(group_secret + domain)",
  "group_secret": "32-byte base64url",
  "role": "primary",
  "primary_endpoint_id": "iroh endpoint id",
  "endpoint_ticket": "iroh endpoint ticket",
  "relay_mode": "public_best_effort",
  "relay_urls": []
}
```

约束：

- `group_secret` 使用 CSPRNG 生成，至少 32 字节；不能使用用户输入的短群号直接作为密钥。
- `group_id` 只作发现和展示标识，不承担认证。
- 加入时使用 challenge-response：`HMAC-SHA256(group_secret, nonce || endpoint_id || protocol)`。
- 所有业务帧必须在已认证的 QUIC 会话内发送；relay 只能看到加密传输元数据。
- 同步码导入时验证协议版本、字段白名单、长度、base64、checksum 和 ticket 格式。
- 普通设置导入导出不包含 `group_secret`、Endpoint 私钥、relay 认证凭据。
- 第一版设备撤销通过主节点成员 allowlist 完成；密钥轮换另列后续协议。

## 5. Dart 同步接口

现有 `SyncTransport` 继续作为业务同步抽象，生命周期单独由
`SyncTransportLifecycle` 承担，selector 根据 `SyncMode` 切换实现：

```dart
enum SyncMode { local, cloud, group }

enum SyncTransportEventKind {
  connected,
  disconnected,
  changesAvailable,
  primaryChanged,
  authenticationFailed,
  error,
}

abstract interface class SyncTransport {
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  });
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  });
}

abstract interface class SyncTransportLifecycle {
  Stream<SyncTransportEvent> get events;
  Future<void> start();
  Future<void> close();
}

class SyncTransportSelector implements SyncTransport, SyncTransportLifecycle {
  SyncTransportSelector({
    required SyncTransport cloudTransport,
    required Future<SyncTransport?> Function() groupTransportFactory,
  });
  // cloudTransport remains the existing HTTP implementation. The group
  // factory is lazy, so local/cloud startup does not load native libraries.
}
```

实施时优先保持现有 `push`/`pull` 方法签名，若生命周期扩展导致接口变胖，则拆分为 `SyncTransport`、`SyncTransportLifecycle` 两个小接口，避免让 HTTP mock 实现无意义地实现 P2P 方法。

新增领域模型：

```dart
class SyncGroupProfile {
  final int protocolVersion;
  final String groupId;
  final String groupSecret;
  final SyncGroupRole role;
  final String primaryEndpointId;
  final String endpointTicket;
  final SyncRelayMode relayMode;
  final List<String> relayUrls;
  final int topologyEpoch;
}
```

`SyncCoordinator` 只依赖抽象和 `SyncMode`，不判断 Iroh 细节。`changesAvailable` 只触发已有 `synchronize()`，不会携带或直接应用完整 change，防止通知丢失和乱序造成数据缺口。

## 6. 主节点权威存储

客户端 SQLite 的 `outbox`、`sync_state` 和 `sync_conflicts` 继续负责本地消费。主节点新增独立表，不能复用客户端表语义：

```sql
sync_authority_change_log(
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  change_id TEXT UNIQUE NOT NULL,
  device_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  entity_version INTEGER NOT NULL,
  changed_at TEXT NOT NULL,
  payload_json TEXT NOT NULL
)

sync_authority_entity_heads(
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  change_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  entity_version INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  PRIMARY KEY (entity_type, entity_id)
)

sync_authority_requests(
  idempotency_key TEXT PRIMARY KEY NOT NULL,
  request_hash TEXT NOT NULL,
  response_json TEXT NOT NULL,
  created_at TEXT NOT NULL
)

sync_group_members(
  endpoint_id TEXT PRIMARY KEY NOT NULL,
  device_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL,
  joined_at TEXT NOT NULL,
  last_seen_at TEXT
)
```

主节点的 push/pull 语义必须与现有 Worker 保持一致：

- push 事务内验证 batch、幂等键、成员权限、实体约束、LWW 冲突和 change log。
- accepted 只在权威日志提交后返回。
- pull 使用 `cur_<sequence>`，按 sequence 升序分页。
- `changes_available` 只广播最新 cursor，不改变 cursor 提交规则。

## 7. Iroh/Rust bridge

Iroh core 通过仓库内 Rust crate 包装，不在 Dart 层手写 UDP/NAT/QUIC。当前使用
稳定 C ABI + Dart FFI 边界；`iroh_endpoint.rs` 负责 endpoint、ticket、connect、
accept 和 QUIC request/response，`session.rs` 负责有界 frame session。

Rust 内部模块：

```text
easycalendar_p2p/
  protocol.rs       帧类型、版本、长度限制
  auth.rs           group_secret challenge-response
  endpoint.rs       Iroh Endpoint 启停、dial、accept
  session.rs        push/pull/notification 请求响应
  error.rs          稳定错误码
```

稳定错误码：

```text
invalid_code
unsupported_protocol
authentication_failed
member_revoked
primary_unavailable
frame_too_large
invalid_change
cursor_invalid
transport_unavailable
```

Iroh relay 默认使用公共尽力而为模式；relay 配置必须可替换，不能把项目方 API key 固化进客户端。生产说明必须明确：Iroh 开源免费，公共 relay 不保证 SLA；用户可选择直连、公共 relay 或自建 relay。当前本地机器未安装 Rust 工具链，native 检查以 CI 的 `cargo fmt --check` 和 `cargo test` 为准。

## 8. 平台策略

- Windows/macOS：桌面 App 生命周期内启动 Endpoint；关闭 App 即主节点离线。
- Android：先实现前台服务适配和常驻通知开关；没有开启前台服务时只保证 App 前台同步。
- iOS：实现前台连接、后台短任务和启动恢复；UI 明确“iOS 无法保证后台常驻主节点”。
- Web 不纳入范围；当前 SQLite/path-provider 架构也未支持 Web。
- 所有平台必须支持 graceful close，避免主节点成员表长期显示在线。

## 9. 提交和验收计划

每个里程碑单独提交，提交前必须通过对应检查；不执行 push 或 merge。

1. `docs: define p2p sync architecture`：本文件；检查 Git diff、Markdown 链接和工作树。
2. `refactor: add sync mode profiles`：`SyncMode` 和配置兼容层；运行 Flutter analyze、同步相关测试。
3. `feat: add sync group code`：同步码编解码、checksum、密钥模型；运行 Dart 单元测试。
4. `feat: add authority schema`：本地 authority migration 和 repository；运行 migration、repository 测试。
5. `test: add star protocol simulation`：内存主从网络和端到端协议测试；验证离线、重试、幂等、冲突。
6. `feat: add rust p2p bridge`：Rust crate、FFI 和最小 endpoint；运行 `cargo fmt --check`、`cargo test`、Flutter analyze。
7. `feat: implement group transport`：Iroh transport、主节点 handler、通知和 cursor pull；运行 Rust/Flutter/Worker 全量检查。
8. `feat: add group setup ui`：首次启动、设置、文本码导入导出；运行 Flutter analyze、同步存储和 selector 测试。
9. `feat: add platform lifecycle support`：Android 前台服务、桌面 close、iOS 限制文案和 CI 原生构建检查。
10. `docs: document p2p operations`：可靠性、隐私、relay、主节点离线和恢复说明；运行最终质量门禁。

## 10. 风险闸门

以下任一条件不满足时，不进入下一阶段：

- Iroh FFI 无法在 Android、Windows 或 macOS 构建，停止在 Rust bridge 阶段并评估替代绑定；iOS 静态链接另列后续里程碑。
- 主节点重启后无法恢复 sequence、幂等和 entity head，停止 authority 阶段。
- 端到端测试出现 outbox 过早删除或 cursor 跳跃，停止 transport 阶段。
- 公共 relay 的服务条款、费用或默认行为不清楚，不在文案中承诺生产可靠性。
- 任一已有 Cloudflare sync 测试回归，立即修复兼容层，不改旧协议。

## 11. 当前实施顺序

第 1-9 项及第 8a、8b 已完成；第 10 项剩余 hosted CI 首次构建、真实公网端到端
验证和最终发布文案。Iroh 原生依赖保持在 bridge/transport 边界，不进入 Dart 业务
层。未完成第 10 项前，Cloudflare 仍是稳定的公网同步方案。
