# 实现与验收说明

实现位于 `codex/miniwatts-pro-analysis`，远端为 `git@github.com:Ccat-Q/MiniWatts-Pro.git`。
功能规范见 [analysis-design.md](analysis-design.md)，实施依据见 [implementation-plan.md](implementation-plan.md)。

## 功能落点

| 功能 | 实现 |
| --- | --- |
| 独立应用、小组件与共享组 | Xcode 工程、两个 entitlements、`WidgetSnapshot` |
| 默认 100% 的可调目标与剩余时间状态 | `ChargePredictor`、`PowerMonitor`、`ChargePredictionPanel` |
| 完整采样、摘要索引、恢复及清理 | `ChargeSession`、`SessionStore` |
| 日期筛选、加权汇总与同电量区间指标 | `ChargeAnalysis`、`ChargeRangeMetrics`、`SessionsView` |
| 单次与日期范围报告 | `ReportGenerator`、`ReportCSV`、`ReportExportController` |
| 瞬时／累计充电转换效率 | `ChargeEfficiency`、`PowerSnapshot`、`EnergyTotals`、`AnalysisTotals` |
| 数字与圆弧局部动画、减少动态效果与滚动暂停 | `ReadoutTransition`、`ReadoutScrollMotion`、`Metric`、`PowerRing` |
| 灵动岛暂停／恢复与本地发布限频 | `ChargeActivityController`、`LiveActivityUpdateGate`、`FloatingMeterController`、`RootView`、`ChargeLiveActivity` |

历史比较检查所选电量区间的覆盖率。能量和平均功率使用边界累计计量值，记录峰值和温度使用完整保存的样本；详情和报告明确这个口径。屏幕曲线抽点只减少绘图负担，保留观测断点与局部极值，不影响存储、计算或导出。

区间 PDF 使用冻结的摘要，CSV 逐会话加载完整曲线。导出期间所选记录被删除或发生变化时，停止并提示重试，不静默漏行。中英文表头注明单位，CSV 时间统一为 UTC，空读数保留空单元格。

## Actions 自动验证

[Build 工作流](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml) 执行全部编译与自动化测试。本地仅检查源码 diff、JSON、plist、entitlements 和脚本语法。

- `Tests/AnalyticsTests.swift`：完整电量边界、90% 覆盖资格、区间外缺口、区间功率/能量/温度、能量加权、缺测与实测零值、日期筛选、历史与本次趋势、尾段减速、目标变化、暂停与观测中断。
- 同一模型测试验证瞬时与累计转换效率、实测零值/净放电、低输入、非有限读数、100% 显示边界，以及同期能量和跨会话能量加权；报告测试检查中英文效率名称及同期计量说明。
- 模型测试遍历全部 50%–100% 目标，检查积累进度、非法电量及未来观测；本地实时活动限频测试覆盖变化读数、心跳、暂停／恢复强制提交与系统时间变化。
- `UITests/ChargingInteractionTests.swift` 在真实应用进程点击 80%／90%／100% 快捷按钮和 Stepper 加减控件，检查 50%／100% 边界、连续点击不崩溃、重启后保留目标及前后台往返。由 `scripts/test-interactions.sh` 在 Actions 运行，并保留 `.xcresult`、日志和截图；补充纯计算测试无法覆盖的 Observation setter 与 SwiftUI 绑定。
- 同一模型测试验证超过 60 次会话与超过 1,500 点仍完整保存、未结束会话保护、强退恢复、索引重建、损坏会话隔离、写入失败及删除后延迟保存不会复活记录。
- `Tests/ReportTests.swift` 与 `scripts/test-reports.sh`：在 iOS 模拟器运行真实 PDF/CSV 生成器，验证中英文、分页、统一汇总、完整采样行数、空范围、数据变化、生成前与生成中的取消、临时文件清理及页面渲染。
- `scripts/verify-identity.py`：检查 IPA 内应用与小组件标识、显示名称、版本、iOS 17 部署目标和源配置共享组。
- `scripts/verify-clean.sh`：检查 IPA 不含签名、描述文件、团队标识或构建机器路径。

报告模拟器与应用 UI 模拟器分别在两个 macOS job 并行运行，模型与存储测试随报告 job 执行；两个 job 都通过后，`ipa` job 才构建、校验并上传交付 IPA。不会在同一 runner 争抢模拟器资源。UI job 提前启动模拟器，编译与启动重叠，由 `xcodebuild test` 在安装运行前等待设备就绪。

使用 `actions/cache@v4` 分别缓存报告／模型模块、模拟器 Debug 与真机 Release 的 DerivedData 编译目录。缓存键包含 runner 系统与架构、Xcode／Swift／SDK／macOS 指纹、构建脚本及工程配置和源码哈希；只从相同工具链与配置恢复旧源码缓存，之后仍由编译器判断需要重编译的内容。测试结果、模拟器用户数据、签名信息和最终 IPA 不进入缓存。缓存命中不跳过测试；首次运行建立缓存，后续命中收益依 runner 排队、启动模拟器和源码改动而异。

每次开发分支推送均触发构建；同一来源仓库与分支的 push、PR 和手动运行共享调度组，保留最新一次完整验证，自动取消已被替代或重复的运行，避免模拟器 job 被重复构建挤占。不同版本标签分组独立，不互相取消。交付时提供对应最终提交的成功运行链接；只有 `v*` 标签才发布 Release。

产物：`MiniWattsPro-unsigned.ipa`、`MiniWatts-dSYM`、`report-test-fixtures`、`interaction-test-results`。IPA 使用 `actions/upload-artifact@v7` 的 `archive: false` 上传，浏览器直接下载 IPA，不再套一层需要解压的 ZIP；旧运行的 ZIP 不受此配置变更影响。报告测试产物来自合成数据，包含中英文单次/区间 PDF、两类 CSV 和页面预览，并非真实设备的充电报告。

## 真机验收边界

Actions 成功证明源码可编译及合成数据规则通过，不证明私有传感器在所有机型上的含义或预测误差。安装后仍需检查：

1. 与 MiniWatts 共存、签名后的 App Group 共享、小组件和实时活动。
2. 暂停/恢复、锁屏或浮窗时的实际采样，以及基于真实记录的剩余时间误差。
3. 明暗外观、中文和大字体的布局、长历史滚动。
4. 系统分享面板的保存/分享/取消，以及清理后当前充电继续记录。
5. 每秒数字更新时的真机 CPU 与滚动流畅度；iOS 18+ 滚动阶段暂停、iOS 17 局部动画、减少动态效果、缺测恢复及大字体布局。

用户报告环境为 iPhone 17 / iOS 27.0.1。Actions 使用 runner 提供的最新可用模拟器，不能替代该真机上的私有传感器、圆弧性能、PiP 保活及 ActivityKit 实际渲染验收。后台挂起时明确暂停，开启浮窗保持运行或返回前台后才恢复真实读数；不承诺后台持续执行。
