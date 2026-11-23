using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Actape.Windows.Core;

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
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
#if ACTAPE_PREVIEW
        // Preview builds must not overwrite the user's stable v1.0.1 macros.
        var dir = Path.Combine(appData, "Actape", "Windows-Preview");
        var legacyPath = Path.Combine(appData, "Actape", "Windows", "macros.json");
#else
        var dir = Path.Combine(appData, "Actape", "Windows");
        var legacyPath = Path.Combine(appData, "Macrobot", "Windows", "macros.json");
#endif
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "macros.json");

        // Preserve macros created by earlier Macrobot preview builds.
        if (!File.Exists(_path) && File.Exists(legacyPath))
            File.Copy(legacyPath, _path, overwrite: false);
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
