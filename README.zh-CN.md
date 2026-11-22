# Macrobot 鼠标宏录制器

基于 [illixion/MacroBot](https://github.com/illixion/MacroBot)（MIT 许可）二次开发的原生鼠标宏工具，目标是用一个 App 完成**录制、编辑、绑定鼠标侧键和执行**，无需额外安装按键映射软件。

## 平台进度

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| macOS | 中文测试版，用户已完成真实侧键测试 | SwiftUI + CoreGraphics；直接绑定侧键，单击开始/再次按下停止 |
| Windows | 开发中 | WPF + Win32 低级输入钩子与 SendInput，目标保持一致的中文操作流程 |

> 当前 macOS 代码尚未实现先前讨论的「按住侧键连续循环、松开立即停止」，不能将现有测试版标为完整 V1。Windows 将以该规则为目标开发，之后再同步补齐 macOS。

## macOS 已有功能

- 鼠标点击、拖动、滚动、键盘操作录制与回放
- 编辑步骤、执行次数、速度，自动保存和 JSON 导入导出
- 直接按真实鼠标侧键完成宏绑定、重绑、清除，无需第二个按键映射程序
- 中文界面与系统菜单、全局 F6 录制和 F7 回放快捷键
- 系统级权限引导：macOS 27 使用「设备控制和数据访问」，较旧系统使用「辅助功能」

本项目不使用原作者发布的安装包作为修改版。macOS 本地编译：

```sh
xcodebuild -project Macrobot.xcodeproj -scheme Macrobot -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**注意：** 临时签名的测试版重新编译、签名后，macOS 授权可能因签名身份变化而失效。正式分发应采用稳定开发者签名，或针对改版进行重新授权。

## Windows 开发

Windows 源码位于 `Windows/Macrobot.Windows`，使用 Windows 10/11 原生输入接口和 WPF；运行时使用一个应用，不要求安装 Karabiner 或鼠标驱动映射程序。录制侧键采用 XBUTTON1/XBUTTON2 标准事件；部分厂家固件按键可能不提供这些标准事件。

请见 `docs/MOUSE_BUTTON_TRIGGER.md` 和后续 Windows README。

## 协议

保留原作者 MIT 许可证及版权说明，详见 [LICENSE](LICENSE)。Windows 的独立实现同样遵循 MIT 条款。
