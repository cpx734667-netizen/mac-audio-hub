using System.Text.Json;
using System.Text.Json.Serialization;

namespace AirMicHub.Core;

/// <summary>Well-known build/version facts shown in the UI and health endpoints.</summary>
public static class BuildInfo
{
    public const string ProductName = "AirMic Hub";
    public const string Version = "1.0.0";
    public const string ServerTag = "AirMic";
    public const string WindowsEdition = "Windows";
}

public static class AppPaths
{
    public static string BaseDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AirMicHub");

    public static string CertificatePath => Path.Combine(BaseDirectory, "cert.pfx");
    public static string SettingsPath => Path.Combine(BaseDirectory, "settings.json");
    public static string LogDirectory => Path.Combine(BaseDirectory, "logs");
    public static string CacheDirectory => Path.Combine(BaseDirectory, "cache");

    public static string EnsureBaseDirectory()
    {
        Directory.CreateDirectory(BaseDirectory);
        return BaseDirectory;
    }

    public static string EnsureLogDirectory()
    {
        Directory.CreateDirectory(LogDirectory);
        return LogDirectory;
    }

    public static string EnsureCacheDirectory()
    {
        Directory.CreateDirectory(CacheDirectory);
        return CacheDirectory;
    }
}

public sealed class AppSettings
{
    public int MicPort { get; set; } = 8765;
    public int SpeakerPort { get; set; } = 8787;
    public string? OutputDeviceId { get; set; }
    public string? InputDeviceId { get; set; }
    public string? LanAddress { get; set; }
    public bool LocalMicEnabled { get; set; }
    public bool CaptureEnabled { get; set; } = true;
    /// <summary>"auto" | "process" | "loopback"</summary>
    public string CaptureMode { get; set; } = "auto";
    public bool EfficientMode { get; set; }
    public float Volume { get; set; } = 0.9f;
    public double LyricOffsetSeconds { get; set; }

    [JsonIgnore]
    public string FilePath { get; private set; } = AppPaths.SettingsPath;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static AppSettings Load(string? path = null)
    {
        path ??= AppPaths.SettingsPath;
        try
        {
            if (!File.Exists(path)) return new AppSettings { FilePath = path };
            var json = File.ReadAllText(path);
            var settings = JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
            settings.FilePath = path;
            settings.Normalize();
            return settings;
        }
        catch (Exception ex)
        {
            Log.Warn($"读取设置失败，使用默认值：{ex.Message}");
            return new AppSettings { FilePath = path };
        }
    }

    public void Normalize()
    {
        if (MicPort is < 1 or > 65535) MicPort = 8765;
        if (SpeakerPort is < 1 or > 65535) SpeakerPort = 8787;
        if (MicPort == SpeakerPort) SpeakerPort = 8787;
        Volume = Math.Clamp(Volume, 0f, 1f);
        CaptureMode = (CaptureMode ?? "auto").ToLowerInvariant() switch
        {
            "process" => "process",
            "loopback" => "loopback",
            _ => "auto",
        };
        LyricOffsetSeconds = Math.Clamp(LyricOffsetSeconds, -30, 30);
    }

    public void Save()
    {
        try
        {
            AppPaths.EnsureBaseDirectory();
            SaveTo(FilePath);
        }
        catch (Exception ex)
        {
            Log.Warn($"保存设置失败：{ex.Message}");
        }
    }

    public void SaveTo(string path)
    {
        var json = JsonSerializer.Serialize(this, JsonOptions);
        var temp = path + ".tmp";
        File.WriteAllText(temp, json);
        File.Move(temp, path, overwrite: true);
    }
}
