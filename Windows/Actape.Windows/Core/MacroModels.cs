using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace Actape.Windows.Core;

public abstract class Notifiable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Notify([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Notify(name);
        return true;
    }
}
public enum SideButton { None, XButton1, XButton2 }
public enum TriggerMode { Tap, Hold }
public enum MouseButton { Left, Right, Middle }
public enum StepKind { Click, MouseDown, MouseUp, Drag, Scroll, KeyDown, KeyUp, TypeText, Wait, KeyCombo }

[Flags]
public enum KeyModifiers { None = 0, Ctrl = 1, Alt = 2, Shift = 4, Win = 8 }

public sealed class MacroStep : Notifiable
{
    private StepKind _kind = StepKind.Click;
    private MouseButton _button = MouseButton.Left;
    private int _x, _y, _endX, _endY, _delayMs = 160, _clickCount = 1, _scrollDelta = 120, _keyCode = 13;
    private KeyModifiers _keyModifiers;
    private bool _horizontal;
    private string _text = "";

    public Guid Id { get; set; } = Guid.NewGuid();
    public StepKind Kind { get => _kind; set { if (Set(ref _kind, value)) Notify(nameof(Summary)); } }
    public MouseButton Button { get => _button; set { if (Set(ref _button, value)) Notify(nameof(Summary)); } }
    public int X { get => _x; set { if (Set(ref _x, value)) { Notify(nameof(Summary)); Notify(nameof(CoordinateSummary)); } } }
    public int Y { get => _y; set { if (Set(ref _y, value)) { Notify(nameof(Summary)); Notify(nameof(CoordinateSummary)); } } }
    public int EndX { get => _endX; set { if (Set(ref _endX, value)) Notify(nameof(Summary)); } }
    public int EndY { get => _endY; set { if (Set(ref _endY, value)) Notify(nameof(Summary)); } }
    public int DelayMs { get => _delayMs; set => Set(ref _delayMs, Math.Clamp(value, 0, 3600000)); }
    public int ClickCount { get => _clickCount; set { if (Set(ref _clickCount, Math.Clamp(value, 1, 99))) Notify(nameof(Summary)); } }
    public int ScrollDelta { get => _scrollDelta; set { if (Set(ref _scrollDelta, value)) Notify(nameof(Summary)); } }
    public bool HorizontalScroll { get => _horizontal; set { if (Set(ref _horizontal, value)) Notify(nameof(Summary)); } }
    public int KeyCode { get => _keyCode; set { if (Set(ref _keyCode, value)) { Notify(nameof(Summary)); Notify(nameof(KeyDisplay)); } } }
    public KeyModifiers KeyModifiers { get => _keyModifiers; set { if (Set(ref _keyModifiers, value)) { Notify(nameof(Summary)); Notify(nameof(KeyDisplay)); } } }

    [JsonIgnore] public string CoordinateSummary => $"保留原坐标  X: {X} · Y: {Y}";
    [JsonIgnore] public string KeyDisplay
    {
        get
        {
            var keys = new List<string>();
            if (KeyModifiers.HasFlag(KeyModifiers.Ctrl)) keys.Add("Ctrl");
            if (KeyModifiers.HasFlag(KeyModifiers.Alt)) keys.Add("Alt");
            if (KeyModifiers.HasFlag(KeyModifiers.Shift)) keys.Add("Shift");
            if (KeyModifiers.HasFlag(KeyModifiers.Win)) keys.Add("Win");
            string primary = Enum.GetName(typeof(System.Windows.Forms.Keys), KeyCode) ?? $"0x{KeyCode:X2}";
            keys.Add(primary switch { "Return" => "Enter", "Space" => "Space", "Escape" => "Esc", _ => primary });
            return string.Join(" + ", keys);
        }
    }
    public string Text { get => _text; set { if (Set(ref _text, value ?? "")) Notify(nameof(Summary)); } }

    [JsonIgnore]
    public string Summary => Kind switch
    {
        StepKind.Click => $"{ButtonName}点击 ({X}, {Y}) ×{ClickCount}",
        StepKind.MouseDown => $"{ButtonName}按下 ({X}, {Y})",
        StepKind.MouseUp => $"{ButtonName}松开 ({X}, {Y})",
        StepKind.Drag => $"拖动 ({X}, {Y}) → ({EndX}, {EndY})",
        StepKind.Scroll => $"{(HorizontalScroll ? "横向" : "纵向")}滚动 {ScrollDelta}",
        StepKind.KeyDown => $"按键按下 0x{KeyCode:X2}",
        StepKind.KeyUp => $"按键松开 0x{KeyCode:X2}",
        StepKind.KeyCombo => $"按键 {KeyDisplay} · 原坐标 ({X}, {Y})",
        StepKind.TypeText => $"输入「{(Text.Length > 26 ? Text[..26] + "…" : Text)}」",
        StepKind.Wait => $"等待 {DelayMs} ms",
        _ => Kind.ToString()
    };

    [JsonIgnore] public string ButtonName => Button switch
    {
        MouseButton.Left => "左键", MouseButton.Right => "右键", _ => "中键"
    };
}

public sealed class Macro : Notifiable
{
    private string _name = "新建宏";
    private SideButton _trigger;
    private TriggerMode _mode = TriggerMode.Tap;
    private int _repeatCount = 1;
    private bool _infinite;
    private double _speed = 1.0;
    private bool _enabled = true;
    private ObservableCollection<MacroStep> _steps = new();

    public Macro() => _steps.CollectionChanged += OnStepsChanged;

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get => _name; set => Set(ref _name, value ?? ""); }
    public SideButton Trigger { get => _trigger; set { if (Set(ref _trigger, value)) Notify(nameof(TriggerDisplay)); } }
    public TriggerMode Mode { get => _mode; set { if (Set(ref _mode, value)) Notify(nameof(TriggerDisplay)); } }
    public int RepeatCount { get => _repeatCount; set => Set(ref _repeatCount, Math.Clamp(value, 1, 100000)); }
    public bool InfiniteLoop { get => _infinite; set => Set(ref _infinite, value); }
    public double Speed { get => _speed; set => Set(ref _speed, Math.Clamp(value, 0.1, 10.0)); }
    public bool Enabled { get => _enabled; set => Set(ref _enabled, value); }
    public ObservableCollection<MacroStep> Steps
    {
        get => _steps;
        set
        {
            _steps.CollectionChanged -= OnStepsChanged;
            _steps = value ?? new ObservableCollection<MacroStep>();
            _steps.CollectionChanged += OnStepsChanged;
            Notify();
            Notify(nameof(StepCount));
        }
    }
    private void OnStepsChanged(object? s, NotifyCollectionChangedEventArgs e) => Notify(nameof(StepCount));

    [JsonIgnore] public int StepCount => Steps.Count;
    [JsonIgnore] public string TriggerDisplay => $"{(Trigger switch
    {
        SideButton.XButton1 => "鼠标侧键 4", SideButton.XButton2 => "鼠标侧键 5", _ => "未绑定"
    })} · {(Mode == TriggerMode.Hold ? "按住触发" : "单击触发")}";
}

public sealed record Option<T>(T Value, string Name);
