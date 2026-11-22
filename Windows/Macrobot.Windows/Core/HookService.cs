using System.Runtime.InteropServices;
namespace Macrobot.Windows.Core;

internal readonly record struct MouseHookEvent(int Message, int X, int Y, uint MouseData);
internal readonly record struct KeyHookEvent(int Message, int VirtualKey);

/// <summary>Global physical-input listener.  Callbacks run on the WPF message-pump thread.</summary>
internal sealed class HookService : IDisposable
{
    private IntPtr _mouse, _keyboard;
    private readonly NativeInput.HookProc _onMouse;
    private readonly NativeInput.HookProc _onKeyboard;

    public event Action<MouseHookEvent>? PhysicalMouse;
    public event Action<KeyHookEvent>? PhysicalKeyboard;

    /// <summary>Return true to consume an assigned side button, suppressing browser Back/Forward.</summary>
    public Func<SideButton, bool, bool>? HandleSideButton { get; set; }
    public Func<int, bool, bool>? HandleShortcut { get; set; }

    public HookService()
    {
        _onMouse = OnMouse;
        _onKeyboard = OnKeyboard;
    }

    public void Start()
    {
        if (_mouse != IntPtr.Zero) return;
        var module = NativeInput.GetModuleHandle(null);
        _mouse = NativeInput.SetWindowsHookEx(NativeInput.WH_MOUSE_LL, _onMouse, module, 0);
        if (_mouse == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "无法安装鼠标监听钩子");
        _keyboard = NativeInput.SetWindowsHookEx(NativeInput.WH_KEYBOARD_LL, _onKeyboard, module, 0);
        if (_keyboard == IntPtr.Zero)
        {
            NativeInput.UnhookWindowsHookEx(_mouse);
            _mouse = IntPtr.Zero;
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "无法安装键盘监听钩子");
        }
    }

    private IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return NativeInput.CallNextHookEx(_mouse, code, wParam, lParam);
        try
        {
            var ev = Marshal.PtrToStructure<NativeInput.MSLLHOOKSTRUCT>(lParam);
            if ((ev.flags & NativeInput.LLMHF_INJECTED) != 0)
                return NativeInput.CallNextHookEx(_mouse, code, wParam, lParam);
            int msg = unchecked((int)wParam.ToInt64());
            if (msg is NativeInput.WM_XBUTTONDOWN or NativeInput.WM_XBUTTONUP)
            {
                int number = (int)((ev.mouseData >> 16) & 0xFFFF);
                var side = number == 1 ? SideButton.XButton1 : number == 2 ? SideButton.XButton2 : SideButton.None;
                if (side != SideButton.None &&
                    (HandleSideButton?.Invoke(side, msg == NativeInput.WM_XBUTTONDOWN) ?? false))
                    return new IntPtr(1);
            }
            PhysicalMouse?.Invoke(new MouseHookEvent(msg, ev.pt.x, ev.pt.y, ev.mouseData));
        }
        catch (Exception e) { System.Diagnostics.Debug.WriteLine("Mouse hook: " + e.Message); }
        return NativeInput.CallNextHookEx(_mouse, code, wParam, lParam);
    }

    private IntPtr OnKeyboard(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return NativeInput.CallNextHookEx(_keyboard, code, wParam, lParam);
        try
        {
            var ev = Marshal.PtrToStructure<NativeInput.KBDLLHOOKSTRUCT>(lParam);
            if ((ev.flags & NativeInput.LLKHF_INJECTED) != 0)
                return NativeInput.CallNextHookEx(_keyboard, code, wParam, lParam);
            var msg = unchecked((int)wParam.ToInt64());
            bool down = msg is NativeInput.WM_KEYDOWN or NativeInput.WM_SYSKEYDOWN;
            if (HandleShortcut?.Invoke((int)ev.vkCode, down) ?? false)
                return new IntPtr(1);
            PhysicalKeyboard?.Invoke(new KeyHookEvent(msg, (int)ev.vkCode));
        }
        catch (Exception e) { System.Diagnostics.Debug.WriteLine("Keyboard hook: " + e.Message); }
        return NativeInput.CallNextHookEx(_keyboard, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (_mouse != IntPtr.Zero) { NativeInput.UnhookWindowsHookEx(_mouse); _mouse = IntPtr.Zero; }
        if (_keyboard != IntPtr.Zero) { NativeInput.UnhookWindowsHookEx(_keyboard); _keyboard = IntPtr.Zero; }
        GC.SuppressFinalize(this);
    }
}
