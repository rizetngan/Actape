# Actape for Windows · v1.1.0

Actape 的原生 Windows 实现。使用一个 App 完成鼠标与键盘操作录制、步骤编辑、统一触发键绑定和宏回放。

## 功能

- 简体中文双栏界面：宏列表、步骤编辑、复制、删除、JSON 导入导出
- 系统级鼠标点击、拖动、滚动录制；可选键盘录制
- 添加步骤：录入操作、输入文字、等待；支持坐标、延迟、点击次数及顺序编辑
- 鼠标侧键 XBUTTON1 / XBUTTON2、键盘单键及组合键均可直接绑定
- 每个宏独立配置单击触发或按住循环、松开停止
- F6 录制/结束，F7 测试执行
- 系统托盘常驻、自动保存、停止时释放模拟按键

## 技术实现

- WPF / C# / .NET 10
- Win32 `WH_MOUSE_LL`、`WH_KEYBOARD_LL` 低级输入钩子
- `SendInput` 执行鼠标与键盘输入
- 使用标准 XBUTTON1 / XBUTTON2 事件识别鼠标侧键

Windows 版本独立实现，不复用 macOS 的 AppKit / CoreGraphics 代码。

## 下载与状态

Actape for Windows 已作为 v1.1.0 正式版发布，已完成本机编译、独立 EXE 启动、基本界面交互与用户实机测试。

正式版请从 [GitHub Releases](https://github.com/rizetngan/Actape/releases/tag/v1.1.0) 下载。开发构建日志可在 [Windows workflow](https://github.com/rizetngan/Actape/actions/workflows/windows-build.yml) 查看。

## 构建

要求 Windows 10/11 与 .NET 10 SDK：

```powershell
dotnet restore Windows/Actape.Windows/Actape.Windows.csproj
dotnet build Windows/Actape.Windows/Actape.Windows.csproj -c Release
dotnet publish Windows/Actape.Windows/Actape.Windows.csproj -c Release -r win-x64 `
  --self-contained true -p:PublishSingleFile=true
```

默认输出为 `Windows/Actape.Windows/bin/Release/net10.0-windows/`。

开发电脑使用 Windows 10 22H2，缺少当前 .NET 10 编译器所需的系统 CET 更新，因此本机预览验证使用独立 .NET 8 SDK 兼容构建；CI 与正式发布仍以受支持的 .NET 10 / Windows 组合为准。不会通过关闭系统安全防护来规避该环境问题。

## 录制与绑定

1. 新建宏，点击「开始录制」，等待 2 秒倒计时。
2. 切换到目标窗口执行操作，按 F6 或点击「完成录制」。
3. 选择步骤可编辑参数、调整顺序；点击「测试执行」进行一次回放。
4. 点击「设置触发键…」，按下鼠标侧键、单键或快捷键组合。
5. 单击模式：按下启动，再次按下停止。按住模式：按住循环执行，松开立即停止。
6. 关闭主窗口后 Actape 留在系统托盘；托盘菜单可暂停、停止或退出。

## 数据与兼容

- 宏数据保存在 `%APPDATA%\Actape\Windows\macros.json`。
- 从旧版 Macrobot 升级时，如果新目录尚无数据，会自动复制 `%APPDATA%\Macrobot\Windows\macros.json`；旧文件保留。
- Windows 与 macOS 当前使用独立数据模型，支持 JSON 导入导出。
- 普通权限的应用无法可靠向管理员权限窗口注入输入（Windows UIPI 限制）。
- 部分鼠标驱动不发送标准 XBUTTON 事件，需按实际设备验证。

## 项目来源与许可

macOS 原始实现基于 [illixion/MacroBot](https://github.com/illixion/MacroBot)（MIT）；Windows 版本为独立实现。上游版权及 [MIT License](../LICENSE) 保留。
