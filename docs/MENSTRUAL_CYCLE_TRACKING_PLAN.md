# 经期记录与预测功能实施计划

状态：首版已实现
适用版本：EasyCalendar `0.1.2+3` 之后  
最后更新：2026-08-31

## 1. 结论

首版应只做“经期记录 + 下一次月经开始时间预测”，不做排卵日、易孕期、避孕或疾病诊断。预测器采用本地、确定性、可解释的稳健统计模型；输入以实际月经开始/结束日期为核心，流量、点滴出血和症状均为可选记录，不参与首版预测。

日历不能只依赖红/粉颜色表达状态：已记录经期使用实心短横线，预测经期使用浅粉色虚线；颜色和线型同时编码。月视图在线号下方标记，周视图在日期标题底部标记，不整格染色，避免与今天、选中、任务截止和事件颜色冲突。

数据默认仅保存在本地 SQLite。首版不进入现有服务端同步、ICS 或普通 JSON 导出；数据库备份会自然包含这些表，但恢复和导出界面必须明确提示其中可能含健康数据。

## 2. 产品范围

### 2.1 首版包含

- 开启/关闭经期跟踪；关闭仅隐藏，不删除记录。
- 新增、编辑和删除一次经期记录，支持“仍在进行中”。
- 记录开始日期、结束日期和可选的每日流量、点滴出血、症状。
- 月视图、周视图的已记录与预测标记。
- 下一次经期的中心预测、预计持续天数、不确定日期范围和产品置信度。
- 识别疑似漏记或明显异常的长周期，要求用户确认后才决定是否纳入模型。
- 单元测试、SQLite 迁移测试、组件测试和可访问性测试。

### 2.2 首版不包含

- 排卵日、易孕期、受孕概率或避孕建议。
- 疾病诊断、就医分诊、药物建议。
- 基于年龄、BMI、体温、LH、睡眠或穿戴设备的模型。
- 云端训练、跨用户训练、神经网络和第三方分析 SDK。
- 服务端同步与共享日历；这需要独立的隐私、加密和账户威胁模型评审。
- 自动创建普通 `CalendarItem`。健康记录与日程实体保持隔离。

## 3. UI 方向（design-taste-frontend）

### 3.1 设计原则

- 延续现有安静、低干扰的 Material 3 日历，不新增营销式页面或主导航目的地。
- 视觉方差 `3/10`，动态强度 `2/10`，信息密度 `6/10`。
- 记录和预测必须用“颜色 + 线型 + 文本语义”三重区分，不能只靠红色深浅。
- 健康信息按需出现；未启用时，现有日历布局完全不变。
- 不使用整格粉色背景。月格中已经同时承载今天、选中、事件点、事件条和任务截止色。

### 3.2 语义色和标记

| 状态 | 颜色建议 | 形状 | 语义标签 |
| --- | --- | --- | --- |
| 已记录经期 | `#A33F49`（现有 tertiary） | 18-22 px 宽、3 px 高实线 | “已记录经期” |
| 预测经期 | `#E8B9C0`，边缘使用 `#A33F49` 60% | 18-22 px 宽、3 px 高虚线/点线 | “预测经期” |
| 预测中心日 | 同预测色 | 虚线略加粗或附小圆点 | “预计开始” |
| 已排除记录 | `onSurfaceVariant` | 中性删除线，仅在详情中显示 | “不参与预测” |

不要把日期数字本身改成红色。日期数字仍遵循今天、选中和非本月的既有优先级，周期状态只占用日期数字下方的固定标记槽。

### 3.3 月视图

改造 `CalendarMonthGrid` 的 `_MonthDayCell` 和 `_DayNumber`：

- 在日期数字下方预留 4 px 高的稳定区域，避免标记出现时改变格子高度。
- 实际经期显示连续感较强的实线；预测经期显示虚线。
- 一天同时存在今天/选中状态时，日期圆形高亮保持不变，标记置于圆形下方。
- 单击日期仍进入日视图；日视图详情区显示完整预测范围，不在月格塞文字。
- 标记不与最多三个事件色点合并，避免把健康状态误解为事件分类。

### 3.4 周视图

改造 `CalendarTimeGrid` 的 `_DateHeader`：

- 在 30 px 日期标题内增加固定的底部标记槽，必要时把标题高度调整到 34 px。
- 标记横跨单日列宽的约 40%，居中放置；不覆盖全天事件行。
- 已记录为实线，预测为虚线。日期列不整体染色。
- 日视图复用同一标题标记，并在全天区域上方显示一行紧凑状态摘要。

### 3.5 图例与详情

- 仅在启用经期跟踪后，于日历工具栏下方显示紧凑图例：“经期记录”实线、“经期预测”虚线。
- 窄屏上图例可收进 `info_outline` 图标菜单，图标提供 Tooltip 和语义标签。
- 日期详情展示：记录状态、开始/第几天/结束、流量（如已填）、预测中心日、可能日期范围、算法更新时间。
- 预测文案使用“预计”和“可能范围”，禁止使用“准确日期”“安全期”等确定性文案。

### 3.6 入口和记录流程

- 设置页新增“健康与隐私”分区，包含“经期跟踪”开关、“查看周期概览”和“管理记录”。不新增底部导航项。
- 日历工具栏在功能启用后增加 `water_drop_outlined` 图标按钮，Tooltip 为“记录经期”。
- 记录使用底部 Sheet（桌面端可用窄对话框），字段顺序：开始日期、结束日期/仍在进行、是否排除预测、可选流量、可选点滴出血、可选症状。
- 编辑历史记录必须保留明确的“删除记录”危险操作，并走二次确认。
- 周期概览显示最近周期长度、经期持续天数、波动范围和下一次预测；它是功能页/Sheet，不是 Dashboard 卡片堆叠。

## 4. 数据标注

### 4.1 预测必需数据

| 字段 | 必需性 | 用途 |
| --- | --- | --- |
| 经期开始日期 | 必需 | 计算相邻周期长度和预测下一次开始日期 |
| 经期结束日期 | 建议；进行中可空 | 估计预计持续天数 |
| 用户更正/删除 | 必需能力 | 防止误录持续污染历史和预测 |
| 是否排除预测 | 必需能力 | 标记怀孕、产后、换药、手术等不可比周期 |

基本预测不需要姓名、年龄、BMI、性活动、体温或定位信息。年龄和 BMI 在群体研究中与周期特征有关，但首版拥有个体历史后收益有限，会增加隐私负担和模型解释成本。

### 4.2 可选记录

- 流量：少量、中等、大量；按日记录。
- 点滴出血：独立布尔值，默认不把它当作经期开始。
- 症状：腹痛、头痛、情绪、疲劳等预定义多选。
- 上下文：怀孕/产后、开始或停止激素避孕、医疗操作、用户自定义“本周期不典型”。

首版预测器只消费经期开始/结束日期和排除标志。可选数据用于回顾，不把“收集更多信息”伪装成“必然更准确”。

### 4.3 记录与预测的来源标注

所有日历状态都应携带来源，而不是把预测写回原始记录：

- `recorded`：用户实际记录。
- `predicted`：算法临时计算。
- `corrected`：用户修改过的实际记录。
- `excluded`：保留但不参与预测。

预测结果包含 `algorithmVersion`、`generatedAt`、`sampleSize`、中心日期、预计持续天数、不确定范围和置信度。预测不持久化为普通事件，避免算法升级后产生陈旧记录。

## 5. Predictor 原理

### 5.1 定义

设第 `i` 次经期的实际开始日期为 `S_i`，结束日期为 `E_i`：

```text
周期长度 L_i = days(S_i - S_(i-1))
经期持续天数 D_i = days(E_i - S_i) + 1
```

日期按本地日历日计算，不按 UTC 小时差计算；模型输入不包含时分秒。

### 5.2 数据清洗

1. 开始日期必须严格递增，重叠记录交由用户合并或修正。
2. 点滴出血默认不创建新的周期开始。
3. 用户明确排除的周期不进入样本，但仍在历史中可见。
4. 不因为记录超出“常见周期范围”就静默删除。异常也可能是真实健康变化。
5. 若某个周期接近个人中位数的两倍，标记“可能漏记”；只有用户确认漏记或错误后才排除/拆分。
6. 最多使用最近 6 个有效完整周期，降低久远模式对当前预测的影响，同时保持实现可解释。

### 5.3 中心预测

首版使用最近有效周期长度的中位数，而不是平均数：

```text
T = median(lastUpTo6(L))
predictedStart(h) = S_n + round(h * T)
predictedDuration = round(median(lastUpTo6(D)))
```

`h=1` 是下一周期。产品默认只保证下一周期；如月视图需要显示后续 2 个周期，可计算 `h=2..3`，但必须扩大不确定范围，且不能给出相同置信度。

选择中位数的原因是它对单次误录、漏记形成的超长周期更稳健。首版不使用“近期加权平均”，因为只有少量样本时权重选择缺乏个体证据，增加复杂度但不一定提高误差表现。

### 5.4 不确定范围

使用稳健离散度而不是只显示一个日期：

```text
M = median(L)
MAD = median(abs(L_i - M))
robustSigma = 1.4826 * MAD
margin(h) = ceil(max(2, robustSigma * sqrt(h)))
possibleRange(h) = predictedStart(h) +/- margin(h)
```

- `2` 天是小样本和 `MAD=0` 时的最小视觉诚实度，不代表医学置信区间。
- 有至少 6 个可回测周期后，用滚动一步预测的绝对误差 80 分位数校准 `margin`，取它与上式的较大值。
- 后续周期的误差随 `sqrt(h)` 扩大。若范围大到失去实际意义，UI 应显示“规律不足，暂不展示远期预测”。

### 5.5 最低样本与产品置信度

| 有效周期区间数 | 行为 | 产品置信度 |
| --- | --- | --- |
| 0-1 | 不显示预测，只提示继续记录 | 不足 |
| 2 | 可显示带宽较大的试算结果 | 低 |
| 3-5 | 显示下一周期和范围 | 中 |
| 6+ 且回测误差稳定 | 显示下一周期；可选显示第 2-3 周期 | 较高 |

“较高”只描述该用户历史数据上的模型稳定性，不表示医学准确性。最终置信度还应被实际回测误差降级，例如范围超过 7 天时最高只能为“低”。

### 5.6 周期进行中的动态行为

- 在预测范围前：正常显示预测。
- 进入预测范围但用户尚未记录：仍显示范围，不自动生成实际记录。
- 超过范围：显示“本次可能延后或漏记，请确认”，停止把每个新日期染成预测色。
- 用户补录后：立即基于修正后的历史重算。
- 上下文发生变化（怀孕/产后、激素避孕变化等）：暂停预测，直到重新积累足够有效周期。

### 5.7 为什么首版不用机器学习

2021 年的大规模研究使用分层生成式概率模型，能够同时估计个人周期和漏记概率，并优于均值、中位数、CNN、RNN、LSTM 基线。该方法依赖 18.6 万用户、200 多万个周期和群体级训练；EasyCalendar 当前没有合规的数据集、训练管线或模型更新治理。直接复制复杂模型会违反 KISS/YAGNI，也无法给用户可靠解释。

纯 Dart 的中位数 + MAD 基线可以离线运行、单测、版本化并做个人回测。只有在匿名、合规、足量数据和明确指标证明其必要后，才评估分层概率模型。

## 6. 科学边界

- 周期长度并非固定 28 天。Bull 等分析 612,613 个排卵周期，平均周期为 29.3 天，并观察到年龄、BMI 及个体差异；该研究同时指出，识别易孕期需要 BBT 等生理参数，不能只看周期长度。
- 漏记是预测数据的核心噪声。Li 等的研究说明，一次漏记会把相邻两个周期合并成异常长周期，预测模型应显式处理依从性或至少提示用户确认。
- 经期开始预测和易孕期预测是两个不同问题。Setton 等对网站和应用的研究中，只有 1 个网站和 3 个应用准确给出预设的易孕窗口，因此本功能不得从“预测下次月经”外推“安全期”或避孕结论。
- 本功能只提供个人记录趋势，不替代医生。持续异常出血、剧烈疼痛、疑似怀孕或长期无月经等情况不能由本算法解释。

## 7. 仓库结构规划

### 7.1 新增文件

```text
client/lib/
  domain/
    cycle_record.dart              # 经期与每日记录实体、值对象和校验
    cycle_prediction.dart          # 预测结果、不确定范围、置信度
    cycle_predictor.dart           # 纯函数/无 IO 的稳健统计预测器
  application/
    cycle_controller.dart          # 加载、编辑、预测、通知 UI
  data/
    cycle_repository.dart          # 专一的数据访问接口
    local_cycle_repository.dart    # SQLite 实现
  features/
    cycle/
      cycle_record_sheet.dart      # 新建/编辑记录
      cycle_summary_page.dart      # 历史、概览、预测详情
      cycle_settings_section.dart  # 健康与隐私设置
    calendar/
      cycle_day_marker.dart        # 月/周共用的实线/虚线标记

client/test/
  cycle_predictor_test.dart
  cycle_controller_test.dart
  local_cycle_repository_test.dart
  local_database_cycle_migration_test.dart
  cycle_day_marker_test.dart
  cycle_calendar_integration_test.dart
```

### 7.2 修改文件

| 文件 | 变更 |
| --- | --- |
| `client/lib/data/local_database_schema.dart` | schema v4 -> v5；创建周期表和索引 |
| `client/lib/main.dart` | 构造 `LocalCycleRepository` 与 `CycleController` |
| `client/lib/app.dart` | 注入周期 controller；可选增加周期语义色 ThemeExtension |
| `client/lib/features/shell/home_shell.dart` | 向日历和设置传递周期 controller，不新增导航项 |
| `client/lib/features/calendar/calendar_page.dart` | 查询可见日期状态、图例、记录入口 |
| `client/lib/features/calendar/calendar_month_grid.dart` | 日期下方标记槽 |
| `client/lib/features/calendar/calendar_time_grid.dart` | 周/日日期标题标记 |
| `client/lib/features/settings/settings_page.dart` | 接入“健康与隐私”分区 |
| `client/lib/features/settings/settings_sections.dart` | 组合周期设置组件 |
| `client/lib/features/transfer/transfer_page.dart` | 备份/恢复健康数据提示，不改变 ICS 语义 |

预计新增约 12-16 个文件、修改 9-11 个文件、增加约 1,000-1,600 行 Dart/测试代码。首版不增加 pub 依赖，不改服务端。

### 7.3 SQLite v5 草案

```sql
CREATE TABLE cycle_periods (
  id TEXT PRIMARY KEY,
  start_date TEXT NOT NULL,
  end_date TEXT,
  excluded_from_prediction INTEGER NOT NULL DEFAULT 0,
  context TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_cycle_periods_start_date
ON cycle_periods(start_date);

CREATE TABLE cycle_daily_logs (
  date TEXT PRIMARY KEY,
  period_id TEXT REFERENCES cycle_periods(id) ON DELETE CASCADE,
  bleeding_level TEXT,
  spotting INTEGER NOT NULL DEFAULT 0,
  symptoms_json TEXT NOT NULL DEFAULT '[]',
  updated_at TEXT NOT NULL
);

CREATE TABLE cycle_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  enabled INTEGER NOT NULL DEFAULT 0,
  forecast_horizon INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);
```

日期使用 `YYYY-MM-DD`，避免时区切换造成开始日漂移。迁移必须同时覆盖全新建库和 v4 升 v5 两条路径。

### 7.4 边界说明

- `CyclePredictor` 只接收 domain 对象，不依赖 Flutter、SQLite、网络或 controller。
- `CycleController` 不并入现有 `ItemController`，避免健康记录、日程 CRUD、同步和通知继续膨胀。
- 日历组件只消费按日期归一化后的 `CycleDayState`，不自行计算预测。
- 不把周期记录加入 `outbox`、`sync_models` 或服务端 API。
- SQLite 整库备份会包含周期数据；ICS 和现有日程 JSON 导出默认排除。

## 8. 实施顺序

1. 领域模型与纯预测器：先以固定样本实现公式、异常输入和回测测试。
2. SQLite v5 与 repository：完成创建、升级、CRUD、事务和恢复测试。
3. `CycleController`：实现启用、记录修正、可见日期状态和预测刷新。
4. 记录 UI：设置入口、Sheet、历史概览和删除确认。
5. 日历 UI：月视图、周视图、日详情与图例。
6. 隐私收尾：备份提示、导出边界、日志脱敏和无障碍语义。
7. 回归验证：Flutter analyze、全量 test、Windows/Android 构建和真机截图核对。

每一步保持可独立测试，不提前引入服务端、机器学习或穿戴设备抽象。

## 9. 验收标准

- 未启用时，月/周/日视图与当前版本像素布局和行为保持一致。
- 已记录与预测在灰阶、色弱场景下仍可通过实线/虚线和语义标签区分。
- 有 0-1 个周期区间时不伪造预测；2 个区间只显示低置信度。
- 修改或排除历史记录后，预测立即且确定性地变化。
- 漏记造成的近双倍周期不会被静默当作正常周期。
- 月视图的事件、任务、今天和选中状态不被周期标记遮挡。
- 周视图标记不覆盖全天事件和时间网格。
- 所有预测都有可能范围、样本量、算法版本和非医疗用途声明。
- 本地数据库迁移可从 v4 无损升级，现有日程数据不变。
- 网络请求、同步 outbox、ICS 和普通日程 JSON 中不出现周期数据。

## 10. 风险与决策点

- **是否显示未来 3 个周期**：建议首版默认 1 个；远期范围快速扩大后，日历会产生错误确定感。
- **是否同步健康数据**：首版明确否。后续需单独确认端到端加密、密钥恢复、删除语义和服务端访问边界。
- **是否记录自由文本**：建议首版不提供，避免敏感内容进入备份、日志或未来同步。
- **是否提示医疗异常**：首版只提示“规律不足/请核对记录”，不设置诊断阈值。
- **是否使用现有 tertiary 红色**：可用于小面积标记；若与今天/截止线混淆，再引入 `CycleColors` ThemeExtension，而不是扩大整套色板。

## 11. 参考资料与开源项目

- Li K, et al. *A predictive model for next cycle start date that accounts for adherence in menstrual self-tracking*. JAMIA, 2021. [PubMed](https://pubmed.ncbi.nlm.nih.gov/34534312/) / [PMC 全文](https://pmc.ncbi.nlm.nih.gov/articles/PMC8714275/)
- Bull JR, et al. *Real-world menstrual cycle characteristics of more than 600,000 menstrual cycles*. npj Digital Medicine, 2019. [PubMed](https://pubmed.ncbi.nlm.nih.gov/31482137/)
- Setton R, et al. *The Accuracy of Web Sites and Cellular Phone Applications in Predicting the Fertile Window*. Obstetrics & Gynecology, 2016. [PubMed](https://pubmed.ncbi.nlm.nih.gov/27275788/)
- [bloodyhealth/drip](https://github.com/bloodyhealth/drip)：GPL-3.0 的本地优先开源周期跟踪应用，可参考其隐私取向、日记录模型和漏记场景。除非许可证兼容性已确认，不直接复制其代码。

当前没有建议直接引入的成熟 Dart 经期预测库。使用仓库内纯 Dart、无依赖、可回测的实现，更符合本项目的 KISS、YAGNI、SOLID 与隐私边界。

## 12. 实施结果

首版已按本计划完成：独立领域模型、`CycleController`、SQLite v5 迁移、本地 repository、记录编辑器、周期概览、设置入口、月/周/日历标记、恢复点隐私提示均已接入。经期数据未加入同步 outbox、普通 JSON 或 ICS，预测结果保持为运行时派生数据。

验证结果：

- `flutter analyze`：通过，0 问题。
- `flutter test --timeout 60s`：通过，共 155 项测试。
- Windows release：构建通过。
- Android release APK：构建通过。

## 13. 下一阶段：经期多端同步

经期数据多端同步已确定为后续需求，但不应直接复用当前日程 `outbox` 的明文实体协议。当前首版仍保持本地隔离；要开启同步，至少需要单独完成以下设计和评审：

- 同步实体：周期记录、每日记录和跟踪设置使用独立实体类型与版本号，不创建普通 `CalendarItem`。
- 隐私边界：同步内容属于健康数据，默认关闭；设置页必须明确同步范围、设备列表和撤回/删除语义。
- 传输保护：服务端不应记录可用于推断健康状态的日志；需要端到端加密或等价的客户端加密方案、密钥初始化、恢复和换机流程。
- 冲突策略：周期记录按实体版本和字段级更新时间合并；重叠日期、删除与编辑冲突必须保留可恢复历史，不能静默覆盖。
- 预测一致性：只同步实际记录和用户设置，不同步预测结果；每台设备按同一 `algorithmVersion` 本地重算，算法升级后可重新生成。
- 导出边界：ICS 和普通日程 JSON 仍不包含经期数据；健康数据导出需要独立的明确操作和警示。
- 验证范围：新增协议兼容、加密失败、撤销设备、离线编辑、重复投递、删除传播和迁移测试后，才进入实现阶段。
