namespace Macrobot.Windows.Core;

/// <summary>Serial, cancellation-safe playback.  Always releases simulated held keys/buttons.</summary>
internal sealed class MacroPlayer
{
    private CancellationTokenSource? _cts;
    private Task? _job;
    private readonly HashSet<int> _pressedKeys = [];
    private readonly HashSet<MouseButton> _pressedMouse = [];
    private readonly object _stateLock = new();

    public bool IsRunning => _cts != null && !_cts.IsCancellationRequested;
    public event Action<int, int>? Progress;
    public event Action<string, bool>? Finished;

    public async Task StartAsync(Macro macro, bool whileHeld, Func<bool>? stillHeld = null)
    {
        // Never allow two playback jobs to inject input concurrently.
        await StopAsync();
        var cts = new CancellationTokenSource();
        _cts = cts;
        var name = macro.Name;
        _job = Task.Run(async () =>
        {
            int round = 0;
            bool cancelled = false;
            string result = name;
            try
            {
                while (true)
                {
                    cts.Token.ThrowIfCancellationRequested();
                    if (whileHeld && (stillHeld == null || !stillHeld())) break;
                    round++;
                    for (int i = 0; i < macro.Steps.Count; i++)
                    {
                        cts.Token.ThrowIfCancellationRequested();
                        if (whileHeld && (stillHeld == null || !stillHeld())) break;
                        var step = macro.Steps[i];
                        Progress?.Invoke(round, i + 1);
                        await Delay(step.DelayMs, macro.Speed, cts.Token);
                        cts.Token.ThrowIfCancellationRequested();
                        if (whileHeld && (stillHeld == null || !stillHeld())) break;
                        await ExecuteStep(step, macro.Speed, cts.Token);
                    }
                    if (!whileHeld && !macro.InfiniteLoop && round >= macro.RepeatCount) break;
                    // A zero-delay macro must not spin at 100% CPU.
                    await Task.Delay(8, cts.Token);
                }
            }
            catch (OperationCanceledException) { cancelled = true; }
            catch (Exception e) { result = "执行失败：" + e.Message; cancelled = true; }
            finally
            {
                ReleaseAll();
                if (ReferenceEquals(_cts, cts))
                {
                    _cts = null;
                }
                cts.Dispose();
                Finished?.Invoke(result, cancelled);
            }
        });
    }

    public void Stop() => _cts?.Cancel();

    public async Task StopAsync()
    {
        _cts?.Cancel();
        if (_job != null)
        {
            try { await _job; } catch (OperationCanceledException) { }
            _job = null;
        }
    }

    private static Task Delay(int ms, double speed, CancellationToken ct) =>
        ms <= 0 ? Task.CompletedTask : Task.Delay(Math.Max(0, (int)(ms / Math.Max(speed, 0.1))), ct);

    private void MouseDown(MouseButton button)
    {
        lock (_stateLock)
        {
            if (_pressedMouse.Add(button)) NativeInput.MouseButtonEvent(button, true);
        }
    }

    private void MouseUp(MouseButton button)
    {
        lock (_stateLock)
        {
            if (_pressedMouse.Remove(button)) NativeInput.MouseButtonEvent(button, false);
        }
    }

    private void KeyDown(int code)
    {
        lock (_stateLock)
        {
            if (_pressedKeys.Add(code)) NativeInput.Key(code, true);
        }
    }

    private void KeyUp(int code)
    {
        lock (_stateLock)
        {
            if (_pressedKeys.Remove(code)) NativeInput.Key(code, false);
        }
    }

    private async Task ExecuteStep(MacroStep step, double speed, CancellationToken ct)
    {
        switch (step.Kind)
        {
            case StepKind.Click:
                NativeInput.SetCursorPos(step.X, step.Y);
                for (int n = 0; n < step.ClickCount; n++)
                {
                    ct.ThrowIfCancellationRequested();
                    MouseDown(step.Button);
                    try { await Delay(38, speed, ct); }
                    finally { MouseUp(step.Button); }
                    if (n + 1 < step.ClickCount) await Delay(70, speed, ct);
                }
                break;
            case StepKind.MouseDown:
                NativeInput.SetCursorPos(step.X, step.Y);
                MouseDown(step.Button);
                break;
            case StepKind.MouseUp:
                NativeInput.SetCursorPos(step.X, step.Y);
                MouseUp(step.Button);
                break;
            case StepKind.Drag:
                NativeInput.SetCursorPos(step.X, step.Y);
                MouseDown(step.Button);
                try
                {
                    for (int n = 1; n <= 12; n++)
                    {
                        ct.ThrowIfCancellationRequested();
                        NativeInput.SetCursorPos(
                            step.X + (step.EndX - step.X) * n / 12,
                            step.Y + (step.EndY - step.Y) * n / 12
                        );
                        await Delay(13, speed, ct);
                    }
                }
                finally { MouseUp(step.Button); }
                break;
            case StepKind.Scroll:
                NativeInput.Wheel(step.ScrollDelta, step.HorizontalScroll);
                break;
            case StepKind.KeyDown:
                KeyDown(step.KeyCode);
                break;
            case StepKind.KeyUp:
                KeyUp(step.KeyCode);
                break;
            case StepKind.TypeText:
                NativeInput.TypeText(step.Text, ct);
                break;
            case StepKind.Wait:
                // DelayMs was already applied before this step.
                break;
        }
    }

    private void ReleaseAll()
    {
        lock (_stateLock)
        {
            foreach (int code in _pressedKeys.ToArray())
            {
                try { NativeInput.Key(code, false); } catch { }
            }
            foreach (var button in _pressedMouse.ToArray())
            {
                try { NativeInput.MouseButtonEvent(button, false); } catch { }
            }
            _pressedKeys.Clear();
            _pressedMouse.Clear();
        }
    }
}
