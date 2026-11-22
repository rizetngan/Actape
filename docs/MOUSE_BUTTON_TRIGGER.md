# macOS 鼠标侧键直接绑定 · 首版开发说明

项目：Actape 的 macOS 鼠标侧键实现说明。macOS 原始代码基于 [illixion/MacroBot](https://github.com/illixion/MacroBot)（MIT 许可）二次开发。
Windows 工作目录：`F:\mac鼠标宏录制`。目标平台是 macOS，不是 Windows。

## 已接入

- 保留原版系统级点击/拖动/滚动/键盘录制、步骤编辑、回放次数与速度。
- 每个宏提供「Mouse button / Bind button」入口：点击后直接按一下鼠标侧键即可录入，无需手填按键编号。
- macOS CoreGraphics 事件监听接收 `otherMouseDown/otherMouseUp`，按 `mouseEventButtonNumber` 区分侧键。
- 已绑定侧键直接触发该宏，且抑制原有浏览器前进/后退动作。
- 同一个侧键只能分配给一个宏；重新绑定时旧分配自动解除。
- 按键首次按下触发一次（按住不持续重复触发）；播放中再次按已绑定按钮会停止当前宏。
- 录制时暂停侧键触发，避免录制操作意外执行宏；不拦截录制时的原始输入。
- 绑定保存到已有 `macros.json` 中的可选 `triggerButton` 字段，兼容旧录制文件。
- 复制、导入宏不继承侧键绑定，以免两个宏抢同一个按钮。
- App 内保留原有全局 F6/F7 快捷键，不依赖 Karabiner 或 mousemap。

## macOS 编译（必须在 Mac 上）

原版项目要求 macOS Tahoe 和 Xcode 26.4+。把整个项目目录复制到 Mac，
在终端进入项目目录后执行：

```bash
xcodebuild -project Actape.xcodeproj -scheme Actape \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

也可以用 Xcode 打开 `Actape.xcodeproj`，选择本机 Mac 运行。
若需要稳定安装包，须进一步配置自己团队的签名/公证，不应沿用上游开发者签名身份。

初次运行后，在「系统设置 → 隐私与安全性 → 辅助功能」授权。
授权后重新进入 App；原本的录制和回放权限仍然需要保留。

## macOS 实机验收清单

1. 创建宏，录制三个不同坐标的点击，修改一次延迟，设置循环次数 2。
2. 在宏详情点「Bind button…」，直接按鼠标前侧键，出现 `Button N`。
3. 切换到别的 App，按相同侧键，按预设顺序与次数执行且不会触发浏览器前进/后退。
4. 按住侧键不放，验证只触发一次。执行期间再次按该侧键，应立即进入停止流程。
5. 创建第二个宏，绑定同一侧键，确认第一个宏的绑定被解除。
6. 录制过程中按侧键，确认不会意外触发已绑定宏。
7. 退出并重新启动，验证绑定仍在且再次触发成功。
8. 清除绑定后，原有鼠标侧键行为应恢复。
9. 检查外接显示器、缩放和不同应用下的坐标回放行为。

## 兼容范围与待验证

本版使用 macOS 系统公开提供的侧键事件（通常为按钮编号 3/4，但依设备不同）。
如果鼠标厂家驱动把侧键转换成键盘快捷键，或者鼠标固件不向系统上报独立侧键事件，
当前监听器就识别不到它；届时需针对具体型号研究 HID 输入或额外输入模式，
不需要用户安装第二个映射工具。

本次工作机是 Windows；这里已完成源码修改和版本检查，但 **尚未在 macOS 上进行
Xcode 编译与真实侧键验收**，因此不能把本版标成可安装正式版。

上游 MIT LICENSE 文件保留，二次发布时应继续保留原版权与许可声明。
