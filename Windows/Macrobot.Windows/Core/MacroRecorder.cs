using System.Diagnostics;
namespace Macrobot.Windows.Core;

/// <summary>Converts physical mouse/key streams into editable, ordered macro steps.</summary>
internal sealed class MacroRecorder
{
    private readonly Stopwatch _clock = new();
    private readonly Dictionary<MouseButton, (int X, int Y, long T)> _mouseDown = [];
    private readonly List<MacroStep> _steps = [];
    private long _lastTime;
    public bool IsRecording { get; private set; }
    public bool CaptureKeyboard { get; set; }
    public IReadOnlyList<MacroStep> Steps => _steps;

    public void Start()
    {
        _steps.Clear(); _mouseDown.Clear();
        _lastTime = 0;
        _clock.Restart();
        IsRecording = true;
    }

    public IReadOnlyList<MacroStep> Stop()
    {
        IsRecording = false;
        _clock.Stop();
        _mouseDown.Clear();
        return _steps.ToList();
    }

    private int Delay(long moment) =>
        _steps.Count == 0 ? 0 : (int)Math.Clamp(moment - _lastTime, 0, 3600000);

    private void Add(MacroStep step, long time)
    {
        _steps.Add(step);
        _lastTime = time;
    }

    public void OnMouse(MouseHookEvent input)
    {
        if (!IsRecording || NativeInput.ForegroundIsThisApp()) return;
        long now = _clock.ElapsedMilliseconds;
        MouseButton? button = input.Message switch
        {
            NativeInput.WM_LBUTTONDOWN or NativeInput.WM_LBUTTONUP => MouseButton.Left,
            NativeInput.WM_RBUTTONDOWN or NativeInput.WM_RBUTTONUP => MouseButton.Right,
            NativeInput.WM_MBUTTONDOWN or NativeInput.WM_MBUTTONUP => MouseButton.Middle,
            _ => null
        };
        if (button != null)
        {
            var b = button.Value;
            bool down = input.Message is NativeInput.WM_LBUTTONDOWN or NativeInput.WM_RBUTTONDOWN or NativeInput.WM_MBUTTONDOWN;
            if (down)
            {
                _mouseDown[b] = (input.X, input.Y, now);
            }
            else if (_mouseDown.Remove(b, out var start))
            {
                int duration = (int)Math.Max(0, now - start.T);
                bool drag = Math.Abs(input.X - start.X) + Math.Abs(input.Y - start.Y) > 8;
                if (drag)
                {
                    Add(new MacroStep {
                        Kind = StepKind.Drag, Button = b,
                        X = start.X, Y = start.Y, EndX = input.X, EndY = input.Y,
                        DelayMs = Delay(start.T)
                    }, now);
                }
                else if (duration > 350)
                {
                    var first = new MacroStep {
                        Kind = StepKind.MouseDown, Button = b,
                        X = start.X, Y = start.Y, DelayMs = Delay(start.T)
                    };
                    Add(first, start.T);
                    Add(new MacroStep {
                        Kind = StepKind.MouseUp, Button = b,
                        X = input.X, Y = input.Y, DelayMs = duration
                    }, now);
                }
                else
                {
                    Add(new MacroStep { Kind = StepKind.Click, Button = b,
                        X = start.X, Y = start.Y, DelayMs = Delay(start.T) }, now);
                }
            }
            return;
        }
        if (input.Message is NativeInput.WM_MOUSEWHEEL or NativeInput.WM_MOUSEHWHEEL)
        {
            int amount = (short)(input.MouseData >> 16);
            Add(new MacroStep { Kind = StepKind.Scroll, ScrollDelta = amount,
                HorizontalScroll = input.Message == NativeInput.WM_MOUSEHWHEEL,
                DelayMs = Delay(now) }, now);
        }
    }

    public void OnKeyboard(KeyHookEvent input)
    {
        if (!IsRecording || !CaptureKeyboard || NativeInput.ForegroundIsThisApp()) return;
        bool down = input.Message is NativeInput.WM_KEYDOWN or NativeInput.WM_SYSKEYDOWN;
        bool up = input.Message is NativeInput.WM_KEYUP or NativeInput.WM_SYSKEYUP;
        if (!down && !up) return;
        long now = _clock.ElapsedMilliseconds;
        Add(new MacroStep { Kind = down ? StepKind.KeyDown : StepKind.KeyUp,
            KeyCode = input.VirtualKey, DelayMs = Delay(now) }, now);
    }
}
