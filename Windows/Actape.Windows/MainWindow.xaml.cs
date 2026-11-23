using System.IO;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Actape.Windows.Core;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;

namespace Actape.Windows;

public partial class MainWindow : Window, INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    private void Notify([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public ObservableCollection<Macro> Macros { get; } = [];
    private Macro? _selectedMacro;
    public Macro? SelectedMacro
    {
        get => _selectedMacro;
        private set { _selectedMacro = value; Notify(); UpdateMacroUI(); }
    }

    private MacroStep? _selectedStep;
    public MacroStep? SelectedStep
    {
        get => _selectedStep;
        private set { _selectedStep = value; Notify(); UpdateStepUI(); }
    }

    private string _statusText = "就绪";
    public string StatusText
    {
        get => _statusText;
        private set { _statusText = value; Notify(); }
    }

    public Option<StepKind>[] StepKindOptions { get; } =
    [
        new(StepKind.Click, "鼠标点击"),
        new(StepKind.KeyCombo, "键盘按键 / 组合键"),
        new(StepKind.MouseDown, "鼠标按下"),
        new(StepKind.MouseUp, "鼠标松开"),
        new(StepKind.Drag, "鼠标拖动"),
        new(StepKind.Scroll, "滚动"),
        new(StepKind.KeyDown, "键盘按下"),
        new(StepKind.KeyUp, "键盘松开"),
        new(StepKind.TypeText, "输入文字"),
        new(StepKind.Wait, "等待")
    ];
    public Option<MouseButton>[] MouseButtonOptions { get; } =
    [
        new(MouseButton.Left, "鼠标左键"),
        new(MouseButton.Right, "鼠标右键"),
        new(MouseButton.Middle, "鼠标中键")
    ];

    private readonly HookService _hooks = new();
    private readonly MacroRecorder _recorder = new();
    private readonly MacroPlayer _player = new();
    private readonly MacroRepository _repository = new();
    private readonly DispatcherTimer _saveTimer = new() { Interval = TimeSpan.FromMilliseconds(450) };
    private readonly HashSet<Macro> _trackedMacros = [];
    private readonly HashSet<MacroStep> _trackedSteps = [];
    private readonly HashSet<SideButton> _physicalDown = [];
    private readonly HashSet<int> _shortcutDown = [];
    private WinForms.NotifyIcon? _tray;
    private bool _exitRequested;
    private bool _enabled = true;
    private bool _capturingTrigger;
    private SideButton _captureReleasePending = SideButton.None;
    private MacroStep? _capturingKeyStep;
    private readonly HashSet<int> _captureHeldModifiers = [];
    private readonly HashSet<int> _captureIgnoreKeyUps = [];
    private int _capturePrimaryKey;
    private KeyModifiers _captureModifiers;
    private int _suppressKeyUp;
    private int _holdButtonCode;
    private SideButton _runningTrigger = SideButton.None;
    private readonly HashSet<int> _pressedKeys = [];
    private readonly HashSet<int> _suppressedTriggerUps = [];
    private readonly HashSet<int> _triggerCaptureHeld = [];
    private int _triggerCapturePrimary;
    private KeyModifiers _triggerCaptureModifiers;
    private int _activeHoldKey;
    private KeyModifiers _activeHoldModifiers;
    private bool _capturingSingleStep;
    private Guid _singleCaptureMacroId;
    private readonly Dictionary<MouseButton, (int X, int Y, long Started)> _singleMouseDown = [];
    private readonly HashSet<int> _singleHeldModifiers = [];
    private int _singlePrimary;
    private KeyModifiers _singleModifiers;
    private CancellationTokenSource? _countdown;
    private Guid _recordingMacroId;
    private bool _initialized;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        _hooks.PhysicalMouse += e =>
        {
            _recorder.OnMouse(e);
            HandleSingleMouse(e);
        };
        _hooks.PhysicalKeyboard += e => _recorder.OnKeyboard(e);
        _hooks.HandleSideButton = HandleSideButton;
        _hooks.HandleShortcut = HandleKeyboardShortcut;

        _player.Progress += (round, step) =>
        {
            Dispatcher.BeginInvoke(() => StatusText = $"正在执行：第 {round} 轮 · 步骤 {step}");
        };
        _player.Finished += (result, stopped) =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                _runningTrigger = SideButton.None;
                Volatile.Write(ref _holdButtonCode, 0);
                if (result.StartsWith("执行失败："))
                    StatusText = result;
                else
                    StatusText = stopped ? "已停止执行" : $"执行完成：{result}";
                UpdateRunButtons();
            });
        };

        _saveTimer.Tick += (_, _) =>
        {
            _saveTimer.Stop();
            try { _repository.Save(Macros); }
            catch (Exception ex) { StatusText = "保存失败：" + ex.Message; }
        };

        foreach (var macro in _repository.Load())
            Macros.Add(macro);
        Macros.CollectionChanged += (_, _) => { RewireModelEvents(); SaveSoon(); UpdateMacroCount(); };
        RewireModelEvents();
        if (Macros.Count == 0)
            Macros.Add(new Macro { Name = "我的第一个宏" });
        MacroList.SelectedIndex = 0;

        ConfigureTray();
        _initialized = true;
        UpdateMacroUI();
        Loaded += (_, _) =>
        {
            try { _hooks.Start(); StatusText = "已启用鼠标与键盘监听，可以开始录制"; }
            catch (Exception ex)
            {
                StatusText = "监听启动失败：" + ex.Message;
                System.Windows.MessageBox.Show(this, StatusText, "Actape", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
    }

    private void RewireModelEvents()
    {
        foreach (var item in _trackedMacros)
        {
            item.PropertyChanged -= MacroChanged;
            item.Steps.CollectionChanged -= StepsChanged;
        }
        foreach (var step in _trackedSteps)
            step.PropertyChanged -= StepChanged;
        _trackedMacros.Clear();
        _trackedSteps.Clear();
        foreach (var item in Macros)
        {
            _trackedMacros.Add(item);
            item.PropertyChanged += MacroChanged;
            item.Steps.CollectionChanged += StepsChanged;
            foreach (var step in item.Steps)
                if (_trackedSteps.Add(step)) step.PropertyChanged += StepChanged;
        }
    }

    private void MacroChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Macro.Steps)) RewireModelEvents();
        UpdateMacroUI();
        SaveSoon();
    }
    private void StepsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        RewireModelEvents();
        SaveSoon();
    }
    private void StepChanged(object? sender, PropertyChangedEventArgs e) => SaveSoon();
    private void SaveSoon()
    {
        if (!_initialized) return;
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void UpdateMacroCount() =>
        MacroCountLabel.Text = $"{Macros.Count} 个宏";

    private void NewMacro_Click(object sender, RoutedEventArgs e) => NewMacro();
    private void NewMacro()
    {
        if (_recorder.IsRecording) { StatusText = "请先结束录制"; return; }
        var macro = new Macro { Name = $"宏 {Macros.Count + 1}" };
        Macros.Add(macro);
        MacroList.SelectedItem = macro;
        StatusText = "已新建宏";
    }

    private void MacroList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        SelectedMacro = MacroList.SelectedItem as Macro;
        SelectedStep = null;
    }

    private void UpdateMacroUI()
    {
        if (!_initialized) return;
        var m = SelectedMacro;
        bool has = m != null;
        MacroNameBox.IsEnabled = has;
        RecordButton.IsEnabled = has && !_player.IsRunning;
        PlayButton.IsEnabled = has && m!.Steps.Count > 0 && !_recorder.IsRecording;
        BindButton.IsEnabled = has && !_recorder.IsRecording && !_player.IsRunning;
        ClearBindButton.IsEnabled = has && m!.HasTrigger;
        AddStepButton.IsEnabled = has && !_recorder.IsRecording && !_capturingSingleStep;
        StepList.IsEnabled = has && !_recorder.IsRecording;
        BoundButtonLabel.Text = m?.TriggerName ?? "未绑定";
        BindButton.Content = _capturingTrigger ? "请按触发键…（取消）" : "设置触发键…";
        TriggerModePicker.SelectedIndex = m?.Mode == TriggerMode.Hold ? 1 : 0;
        RepeatSettings.Visibility = m?.Mode == TriggerMode.Hold ? Visibility.Collapsed : Visibility.Visible;
        HoldHint.Visibility = m?.Mode == TriggerMode.Hold ? Visibility.Visible : Visibility.Collapsed;
        UpdateRunButtons();
        UpdateMacroCount();
    }

    private void UpdateRunButtons()
    {
        if (!_initialized) return;
        RecordButton.Content = _countdown != null ? "取消倒计时" : _recorder.IsRecording ? "■  完成录制" : "●  开始录制";
        PlayButton.Content = _player.IsRunning ? "■  停止执行" : "▶  测试执行";
        PlayButton.IsEnabled = _player.IsRunning || (SelectedMacro?.Steps.Count > 0 && !_recorder.IsRecording);
        RecordButton.IsEnabled = !_player.IsRunning;
    }

    private void TriggerModePicker_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || SelectedMacro is null) return;
        SelectedMacro.Mode = TriggerModePicker.SelectedIndex == 1 ? TriggerMode.Hold : TriggerMode.Tap;
        RepeatSettings.Visibility = SelectedMacro.Mode == TriggerMode.Hold ? Visibility.Collapsed : Visibility.Visible;
        HoldHint.Visibility = SelectedMacro.Mode == TriggerMode.Hold ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BindButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is null || _recorder.IsRecording || _player.IsRunning) return;
        _capturingTrigger = !_capturingTrigger;
        _triggerCaptureHeld.Clear();
        _triggerCapturePrimary = 0;
        _triggerCaptureModifiers = KeyModifiers.None;
        StatusText = _capturingTrigger ? "按下侧键、单键或组合键；Esc 取消" : "已取消绑定";
        UpdateMacroUI();
    }

    private void ClearBindButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is null) return;
        SelectedMacro.Trigger = SideButton.None;
        SelectedMacro.TriggerKeyCode = 0;
        SelectedMacro.TriggerKeyModifiers = KeyModifiers.None;
        _capturingTrigger = false;
        StatusText = "已清除触发键";
        UpdateMacroUI();
    }

    private bool HandleSideButton(SideButton button, bool down)
    {
        // Handle only system XBUTTON1/XBUTTON2. User/vendor-specific buttons can map to keyboard events.
        // Suppress the matching release after capturing a button, even if the newly-bound macro is empty.
        if (!down && _captureReleasePending == button)
        {
            _captureReleasePending = SideButton.None;
            return true;
        }
        if (_capturingTrigger)
        {
            if (down && SelectedMacro != null)
            {
                var id = SelectedMacro.Id;
                _captureReleasePending = button;
                _capturingTrigger = false;
                Dispatcher.BeginInvoke(() => AssignSideTrigger(id, button));
            }
            return true;
        }

        // Keep button-up state balanced even if a binding was cleared while held.
        if (!down) _physicalDown.Remove(button);
        if (_recorder.IsRecording || _capturingSingleStep || !_enabled) return false;
        var target = Macros.FirstOrDefault(m => m.Trigger == button && m.Enabled && m.Steps.Count > 0);
        if (target == null) return false;
        if (!down)
        {
            if (Volatile.Read(ref _holdButtonCode) == (int)button)
            {
                Volatile.Write(ref _holdButtonCode, 0);
                _player.Stop();
            }
            return true;
        }
        if (!_physicalDown.Add(button)) return true;

        if (_player.IsRunning)
        {
            // Repressing a side button stops the active macro; no competing jobs run concurrently.
            _player.Stop();
            return true;
        }

        if (target.Mode == TriggerMode.Hold)
            Volatile.Write(ref _holdButtonCode, (int)button);
        _activeHoldKey = 0;
        _runningTrigger = button;
        MacroList.SelectedItem = target;
        StatusText = target.Mode == TriggerMode.Hold ? "按住侧键循环执行，松开立即停止" : $"执行「{target.Name}」";
        _ = _player.StartAsync(target, target.Mode == TriggerMode.Hold,
            () => Volatile.Read(ref _holdButtonCode) == (int)button);
        UpdateRunButtons();
        return true;
    }

    private static KeyModifiers ModifierForKey(int vk) => vk switch
    {
        0x11 or 0xA2 or 0xA3 => KeyModifiers.Ctrl,
        0x12 or 0xA4 or 0xA5 => KeyModifiers.Alt,
        0x10 or 0xA0 or 0xA1 => KeyModifiers.Shift,
        0x5B or 0x5C => KeyModifiers.Win,
        _ => KeyModifiers.None
    };

    private static KeyModifiers ModifiersOf(IEnumerable<int> keys)
    {
        KeyModifiers flags = KeyModifiers.None;
        foreach (int key in keys) flags |= ModifierForKey(key);
        return flags;
    }

    private void AssignSideTrigger(Guid id, SideButton button)
    {
        var target = Macros.FirstOrDefault(m => m.Id == id);
        if (target == null) return;
        var conflict = Macros.FirstOrDefault(m => m.Id != id && m.Trigger == button);
        if (conflict != null && System.Windows.MessageBox.Show(this,
                $"此侧键已用于「{conflict.Name}」，是否转移给「{target.Name}」？",
                "触发键冲突", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
        {
            StatusText = "已保留原绑定"; UpdateMacroUI(); return;
        }
        if (conflict != null) conflict.Trigger = SideButton.None;
        target.TriggerKeyCode = 0;
        target.TriggerKeyModifiers = KeyModifiers.None;
        target.Trigger = button;
        StatusText = $"已绑定 {target.TriggerName}";
        UpdateMacroUI();
    }

    private void AssignKeyboardTrigger(Guid id, int vk, KeyModifiers modifiers)
    {
        var target = Macros.FirstOrDefault(m => m.Id == id);
        if (target == null) return;
        if (vk is 0x1B or 0x75 or 0x76)
        {
            StatusText = "Esc / F6 / F7 为保留按键，请选择其他触发键";
            UpdateMacroUI(); return;
        }
        var conflict = Macros.FirstOrDefault(m => m.Id != id &&
            m.TriggerKeyCode == vk && m.TriggerKeyModifiers == modifiers);
        if (conflict != null && System.Windows.MessageBox.Show(this,
                $"该快捷键已用于「{conflict.Name}」，是否转移给「{target.Name}」？",
                "触发键冲突", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
        {
            StatusText = "已保留原绑定"; UpdateMacroUI(); return;
        }
        if (modifiers == KeyModifiers.None && vk >= 0x30 && vk <= 0x5A &&
            System.Windows.MessageBox.Show(this,
                "普通单键设为全局触发后，正常打字也会触发宏。仍要绑定吗？",
                "单键触发提示", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            StatusText = "已取消单键绑定"; UpdateMacroUI(); return;
        }
        if (conflict != null)
        {
            conflict.TriggerKeyCode = 0;
            conflict.TriggerKeyModifiers = KeyModifiers.None;
        }
        target.Trigger = SideButton.None;
        target.TriggerKeyModifiers = modifiers;
        target.TriggerKeyCode = vk;
        StatusText = $"已绑定 {target.TriggerName}";
        UpdateMacroUI();
    }

    private void StopKeyboardHoldIfReleased()
    {
        if (_activeHoldKey == 0) return;
        if (!_pressedKeys.Contains(_activeHoldKey) ||
            (ModifiersOf(_pressedKeys) & _activeHoldModifiers) != _activeHoldModifiers)
        {
            _activeHoldKey = 0;
            _activeHoldModifiers = KeyModifiers.None;
            _player.Stop();
        }
    }

    private bool HandleKeyboardShortcut(int vk, bool down)
    {
        if (!down && _suppressKeyUp == vk) { _suppressKeyUp = 0; return true; }
        if (_captureIgnoreKeyUps.Contains(vk))
        {
            if (!down) _captureIgnoreKeyUps.Remove(vk);
            return true;
        }
        if (_capturingKeyStep != null)
        {
            if (vk == 0x1B)
            {
                if (down) { CancelKeyCapture(); StatusText = "已取消按键录入"; }
                _captureIgnoreKeyUps.Add(vk);
                return true;
            }
            if (ModifierForKey(vk) != KeyModifiers.None)
            {
                if (down) _captureHeldModifiers.Add(vk);
                else _captureHeldModifiers.Remove(vk);
                return true;
            }
            if (down && _capturePrimaryKey == 0)
            {
                _capturePrimaryKey = vk;
                _captureModifiers = ModifiersOf(_captureHeldModifiers);
            }
            else if (!down && vk == _capturePrimaryKey)
            {
                var step = _capturingKeyStep;
                var modifiers = _captureModifiers;
                CancelKeyCapture();
                if (step != null)
                {
                    step.KeyCode = vk;
                    step.KeyModifiers = modifiers;
                    step.Kind = StepKind.KeyCombo;
                    StatusText = $"已录入：{step.KeyDisplay}，原坐标保留";
                }
            }
            return true;
        }

        if (_capturingTrigger)
        {
            if (vk == 0x1B)
            {
                if (down)
                {
                    _capturingTrigger = false;
                    _captureIgnoreKeyUps.UnionWith(_triggerCaptureHeld);
                    _triggerCaptureHeld.Clear();
                    _captureIgnoreKeyUps.Add(vk);
                    _triggerCapturePrimary = 0;
                    StatusText = "已取消绑定";
                    UpdateMacroUI();
                }
                return true;
            }
            if (ModifierForKey(vk) != KeyModifiers.None)
            {
                if (down) _triggerCaptureHeld.Add(vk);
                else _triggerCaptureHeld.Remove(vk);
                return true;
            }
            if (down && _triggerCapturePrimary == 0)
            {
                _triggerCapturePrimary = vk;
                _triggerCaptureModifiers = ModifiersOf(_triggerCaptureHeld);
            }
            else if (!down && vk == _triggerCapturePrimary)
            {
                var id = SelectedMacro?.Id;
                var modifiers = _triggerCaptureModifiers;
                _captureIgnoreKeyUps.UnionWith(_triggerCaptureHeld);
                _triggerCaptureHeld.Clear();
                _triggerCapturePrimary = 0;
                _capturingTrigger = false;
                if (id.HasValue)
                    Dispatcher.BeginInvoke(() => AssignKeyboardTrigger(id.Value, vk, modifiers));
            }
            return true;
        }
        if (_capturingSingleStep) return HandleSingleKeyboard(vk, down);

        bool firstDown = down && _pressedKeys.Add(vk);
        if (!down) _pressedKeys.Remove(vk);
        StopKeyboardHoldIfReleased();

        if (_enabled && !_recorder.IsRecording)
        {
            if (!down && _suppressedTriggerUps.Remove(vk)) return true;
            var modifiers = ModifiersOf(_pressedKeys);
            var target = Macros.FirstOrDefault(m => m.TriggerKeyCode == vk
                && m.TriggerKeyModifiers == modifiers && m.Enabled && m.Steps.Count > 0);
            if (target != null && down)
            {
                _suppressedTriggerUps.Add(vk);
                if (firstDown)
                {
                    if (_player.IsRunning) { _player.Stop(); return true; }
                    MacroList.SelectedItem = target;
                    if (target.Mode == TriggerMode.Hold)
                    {
                        _activeHoldKey = vk;
                        _activeHoldModifiers = modifiers;
                    }
                    StatusText = target.Mode == TriggerMode.Hold ? "按住触发键循环执行" : $"执行「{target.Name}」";
                    _ = _player.StartAsync(target, target.Mode == TriggerMode.Hold,
                        () => _activeHoldKey == vk && _pressedKeys.Contains(vk)
                              && (ModifiersOf(_pressedKeys) & modifiers) == modifiers);
                    UpdateRunButtons();
                }
                return true;
            }
        }
        if (vk != 0x75 && vk != 0x76) return false; // F6 / F7
        if (down)
        {
            if (_shortcutDown.Add(vk))
            {
                if (vk == 0x75) _ = ToggleRecordAsync();
                else TogglePlay();
            }
        }
        else _shortcutDown.Remove(vk);
        return true;
    }

    private void RecordButton_Click(object sender, RoutedEventArgs e) => _ = ToggleRecordAsync();

    private async Task ToggleRecordAsync()
    {
        if (_countdown != null)
        {
            _countdown.Cancel();
            _countdown = null;
            StatusText = "已取消录制";
            UpdateRunButtons();
            return;
        }
        if (_recorder.IsRecording) { FinishRecording(); return; }
        if (SelectedMacro is null || _player.IsRunning || _capturingSingleStep) return;
        if (SelectedMacro.Steps.Count > 0 &&
            System.Windows.MessageBox.Show(this, "重新录制会替换当前宏的所有步骤，是否继续？",
                "确认重新录制", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        _capturingTrigger = false;
        var macroId = SelectedMacro.Id;
        var cts = new CancellationTokenSource();
        _countdown = cts;
        UpdateRunButtons();
        try
        {
            for (int i = 2; i > 0; i--)
            {
                StatusText = $"{i} 秒后开始录制，请切换到目标窗口";
                await Task.Delay(1000, cts.Token);
            }
            if (cts.IsCancellationRequested || SelectedMacro?.Id != macroId) return;
            _recordingMacroId = macroId;
            _recorder.CaptureKeyboard = CaptureKeyboardCheck.IsChecked == true;
            _recorder.Start();
            MacroList.IsEnabled = false;
            StatusText = "正在录制… 按 F6 或点击完成录制";
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (ReferenceEquals(_countdown, cts)) _countdown = null;
            cts.Dispose();
            UpdateRunButtons();
        }
    }

    private void FinishRecording()
    {
        var steps = _recorder.Stop();
        MacroList.IsEnabled = true;
        var target = Macros.FirstOrDefault(m => m.Id == _recordingMacroId);
        if (target != null && steps.Count > 0)
        {
            target.Steps = new ObservableCollection<MacroStep>(steps);
            StatusText = $"录制完成：{steps.Count} 步";
            SaveSoon();
        }
        else StatusText = "没有录入有效操作，原有步骤已保留";
        UpdateMacroUI();
    }

    private void PlayButton_Click(object sender, RoutedEventArgs e) => TogglePlay();
    private void TogglePlay()
    {
        if (_player.IsRunning)
        {
            _player.Stop();
            StatusText = "正在停止当前宏…";
            UpdateRunButtons();
            return;
        }
        if (SelectedMacro is null || SelectedMacro.Steps.Count == 0 || _recorder.IsRecording || _capturingSingleStep) return;
        // Toolbar is a safe one-pass preview even if the physical trigger is in hold mode.
        var test = new Macro
        {
            Name = SelectedMacro.Name,
            Steps = new ObservableCollection<MacroStep>(SelectedMacro.Steps),
            RepeatCount = 1, InfiniteLoop = false, Speed = SelectedMacro.Speed
        };
        StatusText = $"测试执行：「{test.Name}」";
        _ = _player.StartAsync(test, false);
        UpdateRunButtons();
    }

    private void StepList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_capturingKeyStep != null) CancelKeyCapture();
        SelectedStep = StepList.SelectedItem as MacroStep;
    }

    private void StepKindCombo_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized) return;
        Dispatcher.BeginInvoke((Action)(() =>
        {
            if (_capturingKeyStep != null && _capturingKeyStep.Kind != StepKind.KeyCombo)
                CancelKeyCapture();
            UpdateStepUI();
        }), DispatcherPriority.Background);
    }

    private void UpdateStepUI()
    {
        if (!_initialized) return;
        bool has = SelectedStep != null;
        NoStepMessage.Visibility = has ? Visibility.Collapsed : Visibility.Visible;
        StepEditorPanel.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        if (!has) return;
        var kind = SelectedStep!.Kind;
        MouseButtonEditor.Visibility = kind is StepKind.Click or StepKind.MouseDown or StepKind.MouseUp or StepKind.Drag
            ? Visibility.Visible : Visibility.Collapsed;
        CoordinatesEditor.Visibility = kind is StepKind.Click or StepKind.MouseDown or StepKind.MouseUp or StepKind.Drag
            ? Visibility.Visible : Visibility.Collapsed;
        DragEditor.Visibility = kind == StepKind.Drag ? Visibility.Visible : Visibility.Collapsed;
        ClickCountEditor.Visibility = kind == StepKind.Click ? Visibility.Visible : Visibility.Collapsed;
        KeyEditor.Visibility = kind is StepKind.KeyDown or StepKind.KeyUp ? Visibility.Visible : Visibility.Collapsed;
        KeyComboEditor.Visibility = kind == StepKind.KeyCombo ? Visibility.Visible : Visibility.Collapsed;
        TextEditor.Visibility = kind == StepKind.TypeText ? Visibility.Visible : Visibility.Collapsed;
        ScrollEditor.Visibility = kind == StepKind.Scroll ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AddStep_Click(object sender, RoutedEventArgs e)
    {
        var menu = new System.Windows.Controls.ContextMenu { PlacementTarget = AddStepButton };
        var capture = new System.Windows.Controls.MenuItem { Header = "录入操作" };
        capture.Click += (_, _) => BeginSingleStepCapture();
        var text = new System.Windows.Controls.MenuItem { Header = "输入文字" };
        text.Click += (_, _) => AddManualStep(StepKind.TypeText);
        var wait = new System.Windows.Controls.MenuItem { Header = "等待" };
        wait.Click += (_, _) => AddManualStep(StepKind.Wait);
        menu.Items.Add(capture);
        menu.Items.Add(text);
        menu.Items.Add(wait);
        menu.IsOpen = true;
    }

    private void AddManualStep(StepKind kind)
    {
        if (SelectedMacro == null || _capturingSingleStep) return;
        var step = new MacroStep { Kind = kind, DelayMs = kind == StepKind.Wait ? 300 : 150 };
        SelectedMacro.Steps.Add(step);
        StepList.SelectedItem = step;
        StepList.ScrollIntoView(step);
    }

    private void BeginSingleStepCapture()
    {
        if (SelectedMacro == null || _capturingTrigger || _recorder.IsRecording || _player.IsRunning) return;
        CancelKeyCapture();
        _capturingSingleStep = true;
        _singleCaptureMacroId = SelectedMacro.Id;
        _singleMouseDown.Clear();
        _singleHeldModifiers.Clear();
        _singlePrimary = 0;
        MacroList.IsEnabled = false;
        StatusText = "请在目标窗口执行一次鼠标或键盘操作，Esc 取消";
        AddStepButton.Content = "正在录入…";
        AddStepButton.IsEnabled = false;
    }

    private void FinishSingleStep(MacroStep step, MacroStep? release = null)
    {
        if (!_capturingSingleStep) return;
        var id = _singleCaptureMacroId;
        CancelSingleStepCapture();
        var macro = Macros.FirstOrDefault(m => m.Id == id);
        if (macro == null) return;
        macro.Steps.Add(step);
        if (release != null) macro.Steps.Add(release);
        StepList.SelectedItem = step;
        StepList.ScrollIntoView(step);
        StatusText = $"已录入：{step.Summary}";
    }

    private void CancelSingleStepCapture()
    {
        _capturingSingleStep = false;
        _singleCaptureMacroId = Guid.Empty;
        _singleMouseDown.Clear();
        _singleHeldModifiers.Clear();
        _singlePrimary = 0;
        if (_initialized)
        {
            MacroList.IsEnabled = true;
            AddStepButton.Content = "＋  添加步骤";
            UpdateMacroUI();
        }
    }

    private bool HandleSingleKeyboard(int vk, bool down)
    {
        if (vk == 0x1B)
        {
            if (down)
            {
                CancelSingleStepCapture();
                StatusText = "已取消录入";
                _captureIgnoreKeyUps.Add(vk);
            }
            return true;
        }
        if (ModifierForKey(vk) != KeyModifiers.None)
        {
            if (down) _singleHeldModifiers.Add(vk);
            else _singleHeldModifiers.Remove(vk);
            return true;
        }
        if (down && _singlePrimary == 0)
        {
            _singlePrimary = vk;
            _singleModifiers = ModifiersOf(_singleHeldModifiers);
        }
        else if (!down && vk == _singlePrimary)
        {
            FinishSingleStep(new MacroStep {
                Kind = StepKind.KeyCombo, KeyCode = vk,
                KeyModifiers = _singleModifiers, DelayMs = 150
            });
        }
        return true; // Capture without writing the shortcut into the active text editor.
    }

    private void HandleSingleMouse(MouseHookEvent ev)
    {
        if (!_capturingSingleStep || NativeInput.ForegroundIsThisApp()) return;
        MouseButton? button = ev.Message switch
        {
            NativeInput.WM_LBUTTONDOWN or NativeInput.WM_LBUTTONUP => MouseButton.Left,
            NativeInput.WM_RBUTTONDOWN or NativeInput.WM_RBUTTONUP => MouseButton.Right,
            NativeInput.WM_MBUTTONDOWN or NativeInput.WM_MBUTTONUP => MouseButton.Middle,
            _ => null
        };
        if (button.HasValue)
        {
            bool down = ev.Message is NativeInput.WM_LBUTTONDOWN or NativeInput.WM_RBUTTONDOWN or NativeInput.WM_MBUTTONDOWN;
            if (down)
            {
                _singleMouseDown[button.Value] = (ev.X, ev.Y, System.Diagnostics.Stopwatch.GetTimestamp());
            }
            else if (_singleMouseDown.Remove(button.Value, out var first))
            {
                int duration = (int)System.Diagnostics.Stopwatch.GetElapsedTime(first.Started).TotalMilliseconds;
                bool drag = Math.Abs(first.X - ev.X) + Math.Abs(first.Y - ev.Y) > 8;
                if (drag)
                    FinishSingleStep(new MacroStep { Kind = StepKind.Drag, Button = button.Value,
                        X = first.X, Y = first.Y, EndX = ev.X, EndY = ev.Y, DelayMs = 150 });
                else if (duration > 350)
                    FinishSingleStep(new MacroStep { Kind = StepKind.MouseDown, Button = button.Value,
                        X = first.X, Y = first.Y, DelayMs = 150 },
                        new MacroStep { Kind = StepKind.MouseUp, Button = button.Value,
                            X = ev.X, Y = ev.Y, DelayMs = duration });
                else
                    FinishSingleStep(new MacroStep { Kind = StepKind.Click, Button = button.Value,
                        X = first.X, Y = first.Y, DelayMs = 150 });
            }
        }
        else if (ev.Message is NativeInput.WM_MOUSEWHEEL or NativeInput.WM_MOUSEHWHEEL)
        {
            FinishSingleStep(new MacroStep { Kind = StepKind.Scroll,
                ScrollDelta = (short)(ev.MouseData >> 16),
                HorizontalScroll = ev.Message == NativeInput.WM_MOUSEHWHEEL, DelayMs = 150 });
        }
    }

    private void MoveStepUp_Click(object sender, RoutedEventArgs e) => MoveStep(-1);
    private void MoveStepDown_Click(object sender, RoutedEventArgs e) => MoveStep(1);
    private void MoveStep(int diff)
    {
        if (SelectedStep is null || SelectedMacro is null) return;
        int from = SelectedMacro.Steps.IndexOf(SelectedStep);
        int to = from + diff;
        if (from >= 0 && to >= 0 && to < SelectedMacro.Steps.Count)
        {
            SelectedMacro.Steps.Move(from, to);
            StepList.SelectedItem = SelectedStep;
        }
    }

    private void DeleteStep_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedStep is null || SelectedMacro is null) return;
        SelectedMacro.Steps.Remove(SelectedStep);
        SelectedStep = null;
    }

    private void CaptureKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedStep?.Kind != StepKind.KeyCombo || _recorder.IsRecording || _player.IsRunning) return;
        if (_capturingKeyStep != null)
        {
            CancelKeyCapture();
            return;
        }
        _capturingKeyStep = SelectedStep;
        _captureHeldModifiers.Clear();
        _capturePrimaryKey = 0;
        _captureModifiers = KeyModifiers.None;
        CaptureKeyButton.Content = "取消录入";
        StatusText = "按下目标按键组合，松开主键后完成；Esc 取消";
    }

    private void CancelKeyCapture()
    {
        _capturingKeyStep = null;
        _capturePrimaryKey = 0;
        _captureModifiers = KeyModifiers.None;
        _captureIgnoreKeyUps.UnionWith(_captureHeldModifiers);
        _captureHeldModifiers.Clear();
        if (_initialized) CaptureKeyButton.Content = "录入按键";
    }

    private void MoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is null) return;
        var menu = new System.Windows.Controls.ContextMenu { PlacementTarget = (System.Windows.Controls.Button)sender };
        var duplicate = new System.Windows.Controls.MenuItem { Header = "复制当前宏" };
        duplicate.Click += (_, _) =>
        {
            var copy = JsonSerializer.Deserialize<Macro>(MacroRepository.SerializeMacro(SelectedMacro), MacroRepository.JsonOptions)!;
            copy.Id = Guid.NewGuid();
            copy.Trigger = SideButton.None;
            copy.TriggerKeyCode = 0;
            copy.TriggerKeyModifiers = KeyModifiers.None;
            copy.Name += " 副本";
            foreach (var step in copy.Steps) step.Id = Guid.NewGuid();
            Macros.Add(copy); MacroList.SelectedItem = copy;
        };
        var delete = new System.Windows.Controls.MenuItem { Header = "删除当前宏" };
        delete.Click += (_, _) =>
        {
            if (SelectedMacro is null) return;
            if (System.Windows.MessageBox.Show(this, $"永久删除「{SelectedMacro.Name}」及全部步骤？",
                "确认删除宏", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            Macros.Remove(SelectedMacro);
            MacroList.SelectedIndex = Math.Min(Macros.Count - 1, 0);
            if (Macros.Count == 0) NewMacro();
        };
        menu.Items.Add(duplicate); menu.Items.Add(delete);
        menu.IsOpen = true;
    }

    private void EnableCheck_Changed(object sender, RoutedEventArgs e)
    {
        if (!_initialized) return;
        _enabled = EnableCheck.IsChecked == true;
        if (!_enabled)
        {
            Volatile.Write(ref _holdButtonCode, 0);
            _player.Stop();
            _physicalDown.Clear();
            _pressedKeys.Clear();
            _activeHoldKey = 0;
            _activeHoldModifiers = KeyModifiers.None;
            _suppressedTriggerUps.Clear();
        }
        StatusText = _enabled ? "已启用所有宏" : "已暂停：鼠标侧键恢复原有功能";
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "宏 JSON 文件 (*.json)|*.json" };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var fresh = MacroRepository.Import(dialog.FileName);
            foreach (var item in fresh)
            {
                item.Id = Guid.NewGuid();
                item.Trigger = SideButton.None;
                item.TriggerKeyCode = 0;
                item.TriggerKeyModifiers = KeyModifiers.None;
                foreach (var step in item.Steps) step.Id = Guid.NewGuid();
                Macros.Add(item);
            }
            if (fresh.Count > 0) MacroList.SelectedItem = fresh[0];
            StatusText = $"已导入 {fresh.Count} 个宏（请重新设置触发键）";
        }
        catch (Exception ex) { StatusText = "导入失败：" + ex.Message; }
    }

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is null) return;
        var dialog = new Microsoft.Win32.SaveFileDialog {
            FileName = "actape-macro.json",
            Filter = "宏 JSON 文件 (*.json)|*.json"
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            File.WriteAllText(dialog.FileName, MacroRepository.SerializeMacro(SelectedMacro));
            StatusText = "已导出当前宏";
        }
        catch (Exception ex) { StatusText = "导出失败：" + ex.Message; }
    }

    private void ConfigureTray()
    {
        _tray = new WinForms.NotifyIcon
        {
            Visible = true,
            Text = "Actape",
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application
        };
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("打开 Actape", null, (_, _) => Dispatcher.Invoke(ShowWindow));
        menu.Items.Add("启用 / 暂停宏", null, (_, _) =>
            Dispatcher.Invoke(() => EnableCheck.IsChecked = EnableCheck.IsChecked != true));
        menu.Items.Add("停止当前执行", null, (_, _) => Dispatcher.Invoke(() => _player.Stop()));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("退出 Actape", null, (_, _) => Dispatcher.Invoke(ExitApp));
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowWindow);
    }

    private void ShowWindow()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void ExitApp()
    {
        _exitRequested = true;
        _countdown?.Cancel();
        _player.Stop();
        _hooks.Dispose();
        _saveTimer.Stop();
        try { _repository.Save(Macros); } catch { }
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); _tray = null; }
        System.Windows.Application.Current.Shutdown();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_exitRequested)
        {
            e.Cancel = true;
            Hide();
            StatusText = "Actape 正在系统托盘中运行";
        }
        base.OnClosing(e);
    }
}
