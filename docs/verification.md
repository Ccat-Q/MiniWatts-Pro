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

历史比较检查所选电量区间的覆盖率。能量和平均功率使用边界累计计量值，记录峰值和温度使用完整保存的样本；详情和报告明确这个口径。屏幕曲线抽点只减少绘图负担，保留观测断点与局部极值，不影响存储、计算或导出。

区间 PDF 使用冻结的摘要，CSV 逐会话加载完整曲线。导出期间所选记录被删除或发生变化时，停止并提示重试，不静默漏行。中英文表头注明单位，CSV 时间统一为 UTC，空读数保留空单元格。

## Actions 自动验证

[Build 工作流](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml) 执行全部编译与自动化测试。本地仅检查源码 diff、JSON、plist、entitlements 和脚本语法。

- `Tests/AnalyticsTests.swift`：完整电量边界、90% 覆盖资格、区间外缺口、区间功率/能量/温度、能量加权、缺测与实测零值、日期筛选、历史与本次趋势、尾段减速、目标变化、暂停与观测中断。
- 同一模型测试验证超过 60 次会话与超过 1,500 点仍完整保存、未结束会话保护、强退恢复、索引重建、损坏会话隔离、写入失败及删除后延迟保存不会复活记录。
- `Tests/ReportTests.swift` 与 `scripts/test-reports.sh`：在 iOS 模拟器运行真实 PDF/CSV 生成器，验证中英文、分页、统一汇总、完整采样行数、空范围、数据变化、生成前与生成中的取消、临时文件清理及页面渲染。
- `scripts/verify-identity.py`：检查 IPA 内应用与小组件标识、显示名称、版本、iOS 17 部署目标和源配置共享组。
- `scripts/verify-clean.sh`：检查 IPA 不含签名、描述文件、团队标识或构建机器路径。

每次开发分支推送均构建。交付时提供对应最终提交的成功运行链接；只有 `v*` 标签才发布 Release。

产物：`MiniWattsPro-unsigned-ipa`、`MiniWatts-dSYM`、`report-test-fixtures`。报告测试产物来自合成数据，包含中英文单次/区间 PDF、两类 CSV 和页面预览，并非真实设备的充电报告。

## 真机验收边界

Actions 成功证明源码可编译及合成数据规则通过，不证明私有传感器在所有机型上的含义或预测误差。安装后仍需检查：

1. 与 MiniWatts 共存、签名后的 App Group 共享、小组件和实时活动。
2. 暂停/恢复、锁屏或浮窗时的实际采样，以及基于真实记录的剩余时间误差。
3. 明暗外观、中文和大字体的布局、长历史滚动。
4. 系统分享面板的保存/分享/取消，以及清理后当前充电继续记录。
