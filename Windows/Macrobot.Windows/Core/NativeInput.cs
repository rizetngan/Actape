using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Macrobot.Windows.Core;

/// <summary>Windows input primitives.  All injected events are marked by Windows as synthetic.</summary>
internal static class NativeInput
{
    internal const int WH_MOUSE_LL = 14, WH_KEYBOARD_LL = 13;
    internal const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
    internal const int WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205;
    internal const int WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208;
    internal const int WM_MOUSEWHEEL = 0x020A, WM_XBUTTONDOWN = 0x020B, WM_XBUTTONUP = 0x020C;
    internal const int WM_MOUSEHWHEEL = 0x020E, WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101;
    internal const int WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    internal const uint LLMHF_INJECTED = 0x00000001, LLKHF_INJECTED = 0x00000010;

    [StructLayout(LayoutKind.Sequential)] internal struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct MSLLHOOKSTRUCT
    {
        public POINT pt; public uint mouseData, flags, time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct KBDLLHOOKSTRUCT
    {
        public uint vkCode, scanCode, flags, time; public UIntPtr dwExtraInfo;
    }

    internal delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    internal static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnhookWindowsHookEx(IntPtr handle);
    [DllImport("user32.dll")]
    internal static extern IntPtr CallNextHookEx(IntPtr handle, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    internal static extern IntPtr GetModuleHandle(string? moduleName);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUTUNION input; }
    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public UIntPtr dwExtraInfo;
    }

    private const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000;
    private const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;

    internal static bool ForegroundIsThisApp()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        GetWindowThreadProcessId(hwnd, out var pid);
        return pid == Environment.ProcessId;
    }

    private static void Inject(INPUT input)
    {
        if (SendInput(1, [input], Marshal.SizeOf<INPUT>()) != 1)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput 未能注入事件（目标窗口可能以管理员权限运行）。");
    }

    internal static void MouseButtonEvent(MouseButton button, bool down)
    {
        uint flags = button switch
        {
            MouseButton.Left => down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP,
            MouseButton.Right => down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP,
            _ => down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP
        };
        Inject(new INPUT { type = INPUT_MOUSE, input = new INPUTUNION {
            mi = new MOUSEINPUT { dwFlags = flags }
        } });
    }

    internal static void Wheel(int delta, bool horizontal)
    {
        Inject(new INPUT { type = INPUT_MOUSE, input = new INPUTUNION {
            mi = new MOUSEINPUT {
                mouseData = unchecked((uint)delta),
                dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL
            }
        } });
    }

    internal static void Key(int vk, bool down)
    {
        if (vk <= 0 || vk >= 256) return;
        Inject(new INPUT { type = INPUT_KEYBOARD, input = new INPUTUNION {
            ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = down ? 0u : KEYEVENTF_KEYUP }
        } });
    }

    internal static void TypeText(string content, CancellationToken token)
    {
        // KEYEVENTF_UNICODE uses UTF-16 code units; surrogate pairs are sent intact.
        foreach (char c in content)
        {
            token.ThrowIfCancellationRequested();
            var stroke = new KEYBDINPUT { wScan = c, dwFlags = KEYEVENTF_UNICODE };
            Inject(new INPUT { type = INPUT_KEYBOARD, input = new INPUTUNION { ki = stroke } });
            stroke.dwFlags |= KEYEVENTF_KEYUP;
            Inject(new INPUT { type = INPUT_KEYBOARD, input = new INPUTUNION { ki = stroke } });
        }
    }
}
