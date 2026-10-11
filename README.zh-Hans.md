# MiniWatts Pro

[English](README.md) · **简体中文**

[![Build](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml/badge.svg)](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml)

一个用 Apple 私有 API 做的 iPhone 电池与充电信息 app。它读取手机自己的电源管理传感器——也就是 iOS 用来控制充电的那一套——显示充电器正在输出多少、其中有多少真正进到电芯、手机自身负载与转换损耗，以及这期间手机里每一个温度传感器的读数。

| 功率 | 温度 | 充电器 | 历史 |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="功率"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="温度"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="充电器"> | <img src="docs/screenshots/history.jpg" width="200" alt="历史"> |

> **只能自签安装。** 用了私有 API，所以永远上不了 App Store，需要你自己签名安装。分析在本地完成，不自动上传数据；只有你主动分享时，报告才会离开设备。

## 安装

从 [Releases](https://github.com/Ccat-Q/MiniWatts-Pro/releases) 或成功的
[Actions 构建](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml) 下载
`MiniWattsPro-unsigned.ipa`，用你自己的 Apple ID 签名安装——[Sideloadly](https://sideloadly.io)、
[AltStore](https://altstore.io)、[SideStore](https://sidestore.io) 和 Xcode 都可以。
免费 Apple ID 可用，但应用 7 天后过期，需要重新签名。

运行要求：iPhone，iOS 17 或更高版本。

也可以在 SideStore 或 AltStore（包括 LiveContainer 自带的 SideStore）里添加这个源，从源里安装，之后新版本会作为更新出现：

```
https://github.com/Ccat-Q/MiniWatts-Pro/releases/latest/download/apps.json
```

LiveContainer 无法运行 App 扩展，所以装在 LiveContainer 里的 MiniWatts Pro 没有小组件，也没有实时活动。

MiniWatts Pro 带有主屏幕与锁定屏幕小组件，以及充电时的实时活动。签名时小组件扩展会多占用一个 App ID——免费 Apple ID 每周只能注册 10 个；如果签名工具提示移除扩展，移除后就没有小组件了。

## 它做不到的事

传感器叫什么、怎么换算、甚至有没有这个传感器，都因 iPhone 机型而异，而且没有任何官方文档。这个版本是在 iPhone Air 上开发和验证的，换一个机型，某项读数可能不存在，也可能名字和实际含义对不上。不可能出现的数值——比如真有人看到充电芯片显示 −9199 °C——会被隐藏而不是显示出来，但一个看着合理、实际却是错的数值拦不住。看到反常的数字，请带上机型标识反馈。

只能显示 iOS 真正交给沙盒应用的数据。电池健康度和循环次数被从注册表里过滤掉了；配件电量（Watch、AirPods）返回的是空列表；无线充电不暴露输入电流，所以用 MagSafe 时只能看到进入电芯的部分；放电功率没有对应传感器，只能按电量百分比估算。充电暂停只能靠行为推断，推断出来的应用会标注 `inferred`。

小组件何时刷新由 iOS 决定，通常每 15 到 60 分钟一次，每个小组件都会标明数据的读取时间。实时活动只在 MiniWatts Pro 运行时更新；App 被挂起后会显示为已暂停。这两者都做不到每秒刷新一次——刷新次数由系统分配，App 说了不算。

想在别的 App 里也看到每秒变化的读数，可以在设置里打开悬浮读数：一个画中画小窗，开着的时候 MiniWatts Pro 会一直运行，所以锁屏后也能继续记录这次充电。代价是更耗电，用完需要自己关掉。它不播放任何声音——画中画本来是视频功能，App 声明音频播放能力也只是因为它。

## 充电分析与报告

MiniWatts Pro 与原版 MiniWatts 独立安装，拥有自己的历史记录，不导入旧版数据。
充电目标可设置为 50%–100%，默认 100%；剩余时间结合本次电量趋势与可比本地
历史，注明估算依据。暂停充电或观测中断时停止有效倒计时。目标只用于预测，
不会控制 iOS 的充电上限。

“分析”页包含总览与记录，支持近 7／30／90 天及自定义日期筛选，有线与无线
分别比较相同电量区间，并展示考虑观测覆盖率的能量与温度统计。全部实际记录的
5 秒样本持续保留，用户可以删除单条、日期范围或全部已结束记录，当前充电继续采样。

单次和日期范围均可导出 PDF，也可通过系统分享面板导出会话摘要与采样两类 CSV。
缺失读数不会填成 0，后台空洞不计入实测。完整说明见[功能规范](docs/analysis-design.md)。

全部编译与自动化测试由 GitHub Actions 执行。开发构建提供 `MiniWattsPro-unsigned.ipa`
工作流产物，版本标签构建发布 Release；界面交互和传感器有效性仍需 iPhone 验证。
验证范围与报告测试产物见[实现与验收说明](docs/verification.md)。

## 构建

Xcode 26 或更高版本，iOS 17 部署目标，无第三方依赖。

在 **Actions → Build → Run workflow** 运行开发构建。工作流先执行模型和存储测试、
中英文 PDF／CSV 模拟器测试及 IPA 身份和隐私检查，再上传 IPA。本次实现不使用本地编译。

[`CLAUDE.md`](CLAUDE.md) 是这个项目的工程笔记：沙盒具体封了哪些 API、结论是怎么验证出来的、每个传感器最后查明是什么，以及这个项目已经踩过的 Swift 6 隔离陷阱。

## 许可

基于 [ResistanceTo 的 MiniWatts](https://github.com/ResistanceTo/MiniWatts)。

Apache 2.0，见 [LICENSE](LICENSE)。读取 PMU 的方法衍生自
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor)（MIT），
`BatteryCenterBridge` 有两处细节参考自 [Batsie](https://github.com/leptos-null/Batsie)。
两者都记录在 [NOTICE](NOTICE) 中，上游的 MIT 声明也逐字保留在那里。

私有 API 可能在任何一次 iOS 更新中变化或消失。
