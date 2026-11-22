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
    private bool _capturingSideButton;
    private SideButton _captureReleasePending = SideButton.None;
    private MacroStep? _capturingKeyStep;
    private int _suppressKeyUp;
    private int _holdButtonCode;
    private SideButton _runningTrigger = SideButton.None;
    private CancellationTokenSource? _countdown;
    private Guid _recordingMacroId;
    private bool _initialized;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        _hooks.PhysicalMouse += e => _recorder.OnMouse(e);
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
        ClearBindButton.IsEnabled = has && m!.Trigger != SideButton.None;
        AddStepButton.IsEnabled = has && !_recorder.IsRecording;
        StepList.IsEnabled = has && !_recorder.IsRecording;
        BoundButtonLabel.Text = m?.Trigger switch
        {
            SideButton.XButton1 => "侧键 4",
            SideButton.XButton2 => "侧键 5",
            _ => "未绑定"
        };
        BindButton.Content = _capturingSideButton ? "请按侧键…" : "绑定侧键…";
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
        _capturingSideButton = !_capturingSideButton;
        StatusText = _capturingSideButton ? "请按需要绑定的真实鼠标侧键（Esc 取消）" : "已取消绑定";
        UpdateMacroUI();
    }

    private void ClearBindButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is null) return;
        SelectedMacro.Trigger = SideButton.None;
        _capturingSideButton = false;
        StatusText = "已清除侧键绑定";
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
        if (_capturingSideButton)
        {
            if (down && SelectedMacro != null)
            {
                foreach (var m in Macros.Where(x => x.Trigger == button && x.Id != SelectedMacro.Id))
                    m.Trigger = SideButton.None;
                SelectedMacro.Trigger = button;
                _captureReleasePending = button;
                _capturingSideButton = false;
                StatusText = $"已将{(button == SideButton.XButton1 ? "侧键 4" : "侧键 5")}绑定至「{SelectedMacro.Name}」";
                UpdateMacroUI();
            }
            return true;
        }

        // Keep button-up state balanced even if a binding was cleared while held.
        if (!down) _physicalDown.Remove(button);
        if (_recorder.IsRecording || !_enabled) return false;
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
        _runningTrigger = button;
        MacroList.SelectedItem = target;
        StatusText = target.Mode == TriggerMode.Hold ? "按住侧键循环执行，松开立即停止" : $"执行「{target.Name}」";
        _ = _player.StartAsync(target, target.Mode == TriggerMode.Hold,
            () => Volatile.Read(ref _holdButtonCode) == (int)button);
        UpdateRunButtons();
        return true;
    }

    private bool HandleKeyboardShortcut(int vk, bool down)
    {
        if (!down && _suppressKeyUp == vk)
        {
            _suppressKeyUp = 0;
            return true;
        }
        if (_capturingKeyStep != null && down)
        {
            if (vk == 0x1B) // Esc cancels
                StatusText = "已取消按键录入";
            else
            {
                _capturingKeyStep.KeyCode = vk;
                StatusText = $"已录入按键：0x{vk:X2}";
            }
            _capturingKeyStep = null;
            _suppressKeyUp = vk;
            CaptureKeyButton.Content = "直接按键录入";
            return true;
        }
        if (_capturingSideButton && down && vk == 0x1B)
        {
            _capturingSideButton = false;
            _suppressKeyUp = vk;
            StatusText = "已取消侧键绑定";
            UpdateMacroUI();
            return true;
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
        return true; // Never record global shortcut keys into the macro
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
        if (SelectedMacro is null || _player.IsRunning) return;
        if (SelectedMacro.Steps.Count > 0 &&
            System.Windows.MessageBox.Show(this, "重新录制会替换当前宏的所有步骤，是否继续？",
                "确认重新录制", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        _capturingSideButton = false;
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
        if (SelectedMacro is null || SelectedMacro.Steps.Count == 0 || _recorder.IsRecording) return;
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

    private void StepList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        SelectedStep = StepList.SelectedItem as MacroStep;

    private void StepKindCombo_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized) return;
        Dispatcher.BeginInvoke((Action)UpdateStepUI, DispatcherPriority.Background);
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
        TextEditor.Visibility = kind == StepKind.TypeText ? Visibility.Visible : Visibility.Collapsed;
        ScrollEditor.Visibility = kind == StepKind.Scroll ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AddStep_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = AddStepButton };
        foreach (var option in StepKindOptions)
        {
            var item = new MenuItem { Header = option.Name, Tag = option.Value };
            item.Click += (_, _) =>
            {
                if (SelectedMacro is null) return;
                var step = new MacroStep { Kind = (StepKind)item.Tag, DelayMs = 150 };
                if (step.Kind == StepKind.TypeText) step.Text = "你好";
                if (step.Kind == StepKind.Wait) step.DelayMs = 300;
                SelectedMacro.Steps.Add(step);
                StepList.SelectedItem = step;
                StepList.ScrollIntoView(step);
            };
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
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
        if (SelectedStep is null) return;
        _capturingKeyStep = SelectedStep;
        CaptureKeyButton.Content = "请按一个按键…";
        StatusText = "直接按下要录入的键，按 Esc 取消";
    }

    private void MoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedMacro is null) return;
        var menu = new ContextMenu { PlacementTarget = (System.Windows.Controls.Button)sender };
        var duplicate = new MenuItem { Header = "复制当前宏" };
        duplicate.Click += (_, _) =>
        {
            var copy = JsonSerializer.Deserialize<Macro>(MacroRepository.SerializeMacro(SelectedMacro), MacroRepository.JsonOptions)!;
            copy.Id = Guid.NewGuid(); copy.Trigger = SideButton.None; copy.Name += " 副本";
            foreach (var step in copy.Steps) step.Id = Guid.NewGuid();
            Macros.Add(copy); MacroList.SelectedItem = copy;
        };
        var delete = new MenuItem { Header = "删除当前宏" };
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
        }
        StatusText = _enabled ? "已启用所有鼠标宏" : "已暂停：鼠标侧键恢复原有功能";
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
                foreach (var step in item.Steps) step.Id = Guid.NewGuid();
                Macros.Add(item);
            }
            if (fresh.Count > 0) MacroList.SelectedItem = fresh[0];
            StatusText = $"已导入 {fresh.Count} 个宏（请重新绑定侧键）";
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
            Text = "Actape 鼠标宏",
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application
        };
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("打开 Actape", null, (_, _) => Dispatcher.Invoke(ShowWindow));
        menu.Items.Add("启用 / 暂停鼠标宏", null, (_, _) =>
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
