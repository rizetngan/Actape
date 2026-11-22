# Macrobot for Windows（开发版）

基于 Macrobot 的产品体验，独立实现原生 Windows 版。**一个 App** 即可录制操作、编辑、绑定鼠标侧键并执行，不依赖额外鼠标映射工具。

Windows 源码：`Windows/Macrobot.Windows/`。使用 WPF、Win32 `WH_MOUSE_LL`、`WH_KEYBOARD_LL` 和 `SendInput`，不复用 macOS 特有的 AppKit/CoreGraphics 代码。

## 当前支持

- 简体中文双栏编辑器，宏列表、复制、删除、导入导出 JSON
- 系统级鼠标点击、拖动、滚动录制；可开启键盘录制
- 步骤坐标、延迟、点击次数、按键与文字输入的编辑和回放
- 点击「绑定侧键」，直接按鼠标 XBUTTON1 / XBUTTON2 完成绑定
- 每个宏独立配置触发方式：单击触发，或按住反复执行、松开停止
- 正在执行时再次按绑定侧键停止；全局暂停后恢复侧键原本用途
- 托盘常驻、F6 录制／结束、F7 测试执行、自动保存到用户目录
- 宏执行取消时主动释放已模拟按下的键盘/鼠标按钮

## 建置与兼容

默认目标框架：`.NET 10 / Windows 10/11`，官方 .NET 10 SDK：

```powershell
dotnet build Windows/Macrobot.Windows/Macrobot.Windows.csproj -c Release
dotnet publish Windows/Macrobot.Windows/Macrobot.Windows.csproj -c Release -r win-x64 `
  --self-contained true -p:PublishSingleFile=true
```

开发电脑为 Windows 10 22H2（19045.2006），缺少 .NET 10 所需的完整 CET 更新，SDK 的编译器会在此旧系统上直接退出。
**不通过关闭 CET 等系统安全防护来解决。**
本地开发态验证可通过独立的 .NET 8 SDK 构建临时兼容版本：

```powershell
& "$env:LOCALAPPDATA\MacrobotSdk\dotnet8\dotnet.exe" msbuild Windows\Macrobot.Windows\Macrobot.Windows.csproj -restore -t:Build -p:TargetFramework=net8.0-windows -p:Configuration=Debug
```

注意：.NET 8 的官方安全支持已经结束，兼容构建仅用于该旧电脑上的开发/验收，不作为面向公众的长期发行版本。正式交付应使用已更新的 Windows 及受支持的 .NET 10。

普通权限的 Windows 应用不能向管理员权限的窗口可靠注入输入（UIPI 机制），而某些鼠标厂家驱动并不向系统发送标准 XBUTTON 事件。这两类限制需要实机单独验证，不能仅凭编译通过宣称完全兼容。

## 录制与绑定

1. 新建宏，点击「开始录制」，有 2 秒准备时间。
2. 切换到目标窗口操作，按 F6 结束录制；编辑步骤后可先点击「测试执行」。
3. 点击「绑定侧键…」，直接按一次实体侧键；支持标准的侧键 4 / 5。
4. 选择单击或按住模式。单击：按一次启动，再按一次停止；按住：按住循环，松开停止。
5. 关闭主窗口后应用留在托盘；托盘菜单可暂停全部宏、停止执行和真正退出。

保存目录：`%APPDATA%\Macrobot\Windows\macros.json`。Windows 版采用自己的 JSON 数据结构，暂不直接载入 macOS 的 Swift `macros.json`；后续统一跨平台兼容格式。

## 项目来源和许可

macOS 原始代码基于 [illixion/MacroBot](https://github.com/illixion/MacroBot)（MIT），原版权及 [LICENSE](../LICENSE) 保留。
