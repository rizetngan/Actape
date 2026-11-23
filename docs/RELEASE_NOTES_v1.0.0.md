# Actape v1.0.0 · 首个正式版本

Actape 是一款轻量级、原生的鼠标与键盘宏工具。录制操作、编辑步骤、绑定鼠标侧键，然后直接执行，无需安装额外的鼠标按键映射软件。

## 下载

- **macOS（Apple Silicon + Intel）：** `Actape-macOS-v1.0.0-universal.zip`
- **Windows 10/11（x64）：** `Actape-Windows-v1.0.0-win-x64.zip`
- **校验文件：** `SHA256SUMS.txt`

## 功能

**两平台共有：** 中文界面、录制鼠标/键盘操作、编辑顺序与延迟、直接绑定侧键、执行宏、保存和导入导出宏数据。

**macOS：** 原生 SwiftUI、全局快捷键、侧键单击触发。当前 macOS 构建**不包含**侧键按住持续循环、松开停止模式。

**Windows：** 原生 WPF、XBUTTON1 / XBUTTON2 侧键绑定、单击触发与按住循环（松开停止）、系统托盘运行和全局快捷键。

## 安装

### macOS

1. 解压 ZIP，将 `Actape.app` 拖入「应用程序」文件夹。
2. 当前提供的 macOS 安装包已进行临时签名，**尚未通过 Apple Developer ID 公证**；首次打开可能受到 Gatekeeper 提示。可在 Finder 右键应用并选择「打开」，按 macOS 提示操作。
3. 首次启动时按应用引导授予系统输入权限：macOS 27 在「隐私与安全性 → 设备控制和数据访问」，较旧系统在「辅助功能」。
4. 若曾安装旧 Macrobot，升级到 Actape 后需重新授权；应用会在首次运行时复制已有宏数据，旧文件不会被删除。

### Windows

1. 解压 ZIP，运行 `Actape.exe`，不需要另装 .NET 运行时。
2. 首次运行若出现 Windows SmartScreen 提示，这是因为目前未采用商业代码签名证书；请确认程序来自本仓库的官方 Release。
3. 按需录制宏，绑定鼠标侧键。普通权限应用无法可靠控制以管理员权限运行的其他程序。

## 开源与致谢

macOS 端基于 [illixion/MacroBot](https://github.com/illixion/MacroBot) 的 MIT 开源代码扩展；Windows 端是独立实现。本项目保留原作者版权与 [MIT 许可证](https://github.com/rizetngan/Actape/blob/main/LICENSE)。

[项目主页](https://github.com/rizetngan/Actape) · [使用说明](https://github.com/rizetngan/Actape#readme) · [问题反馈](https://github.com/rizetngan/Actape/issues)
