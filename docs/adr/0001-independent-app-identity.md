# MiniWatts Pro 使用独立应用身份

用户选择让 MiniWatts Pro 与 MiniWatts 共存，而不是覆盖升级旧版。应用使用 `io.github.ccatq.MiniWattsPro`，小组件使用 `io.github.ccatq.MiniWattsPro.Widget`，App Group 使用 `group.io.github.ccatq.MiniWattsPro`，以隔离安装、偏好和历史记录；相比保留旧标识覆盖升级，这会失去自动继承旧数据的便利。首版从新记录开始，不提供旧历史导入，也不能假定新应用可以直接读取旧应用的容器。
