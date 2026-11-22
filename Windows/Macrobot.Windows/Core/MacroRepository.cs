using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Macrobot.Windows.Core;

internal sealed class MacroRepository
{
    private readonly string _path;
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() }
    };

    public string StoragePath => _path;

    public MacroRepository()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Macrobot", "Windows");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "macros.json");
    }

    public List<Macro> Load()
    {
        if (!File.Exists(_path)) return [];
        try
        {
            return JsonSerializer.Deserialize<List<Macro>>(File.ReadAllText(_path), JsonOptions) ?? [];
        }
        catch (Exception)
        {
            // Preserve the original data for recovery instead of silently overwriting it.
            var backup = _path + ".invalid-" + DateTime.Now.ToString("yyyyMMddHHmmss");
            File.Copy(_path, backup, overwrite: false);
            return [];
        }
    }

    public void Save(IEnumerable<Macro> macros)
    {
        string tmp = _path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(macros, JsonOptions));
        File.Move(tmp, _path, overwrite: true);
    }

    public static string SerializeMacro(Macro macro) =>
        JsonSerializer.Serialize(macro, JsonOptions);

    public static List<Macro> Import(string filename)
    {
        var json = File.ReadAllText(filename);
        try
        {
            return JsonSerializer.Deserialize<List<Macro>>(json, JsonOptions) ?? [];
        }
        catch (JsonException)
        {
            var one = JsonSerializer.Deserialize<Macro>(json, JsonOptions);
            return one is null ? [] : [one];
        }
    }
}
