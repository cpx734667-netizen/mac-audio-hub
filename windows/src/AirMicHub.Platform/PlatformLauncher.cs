using System.Diagnostics;
using Microsoft.Win32;
using AirMicHub.Core;

namespace AirMicHub.Platform;

/// <summary>
/// Starts the user's installed music platform. We never embed or scrape the platform: the
/// buttons only open the desktop app (or its URI scheme) so the user can pick the song and
/// switch between original vocal and backing track inside the platform.
/// </summary>
public static class PlatformLauncher
{
    public sealed record LaunchResult(bool Success, string Message, string Command = "");

    public sealed record PlatformDefinition(
        string Key,
        string DisplayName,
        string[] Executables,
        string[] UriSchemes,
        string[]? RelativePaths = null);

    public static readonly PlatformDefinition Netease = new(
        "netease",
        "网易云音乐",
        new[] { "cloudmusic.exe" },
        new[] { "orpheus://", "cloudmusic://" },
        new[]
        {
            @"NetEase\CloudMusic\cloudmusic.exe",
            @"Netease\CloudMusic\cloudmusic.exe",
            @"CloudMusic\cloudmusic.exe",
        });

    public static readonly PlatformDefinition QqMusic = new(
        "qq",
        "QQ 音乐",
        new[] { "QQMusic.exe" },
        new[] { "qqmusic://" },
        new[]
        {
            @"Tencent\QQMusic\QQMusic.exe",
            @"QQMusic\QQMusic.exe",
        });

    public static readonly PlatformDefinition Kugou = new(
        "kugou",
        "酷狗音乐",
        new[] { "KuGou.exe" },
        new[] { "kugou://" },
        new[]
        {
            @"KuGou\KGMusic\KuGou.exe",
            @"Kugou\KGMusic\KuGou.exe",
        });

    public static IReadOnlyList<PlatformDefinition> All => new[] { Netease, QqMusic, Kugou };

    public static PlatformDefinition? Find(string key) =>
        All.FirstOrDefault(platform => string.Equals(platform.Key, key, StringComparison.OrdinalIgnoreCase));

    public static LaunchResult Open(string key)
    {
        var platform = Find(key);
        if (platform is null) return new LaunchResult(false, "未知的音乐平台。");

        var executable = LocateExecutable(platform);
        if (executable is not null)
        {
            var started = TryStart(executable);
            if (started)
            {
                Log.Info($"已打开 {platform.DisplayName}：{executable}");
                return new LaunchResult(true, $"已打开 {platform.DisplayName}", executable);
            }
        }

        foreach (var scheme in platform.UriSchemes)
        {
            if (TryStart(scheme))
            {
                Log.Info($"已通过 URI 打开 {platform.DisplayName}：{scheme}");
                return new LaunchResult(true, $"已打开 {platform.DisplayName}", scheme);
            }
        }

        return new LaunchResult(
            false,
            $"没有找到 {platform.DisplayName} 的 Windows 客户端。请手动打开平台客户端并播放歌曲；" +
            "也可以在平台设置中把默认播放设备设为同一个音箱。");
    }

    private static string? LocateExecutable(PlatformDefinition platform)
    {
        foreach (var executable in platform.Executables)
        {
            foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
            {
                foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
                {
                    try
                    {
                        using var root = RegistryKey.OpenBaseKey(hive, view);
                        using var key = root.OpenSubKey(
                            $@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{executable}");
                        var path = key?.GetValue(null) as string;
                        if (!string.IsNullOrWhiteSpace(path) && File.Exists(path)) return path;
                    }
                    catch
                    {
                        // Registry access can fail in restricted environments.
                    }
                }
            }
        }

        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };

        if (platform.RelativePaths is not null)
        {
            foreach (var root in roots)
            {
                if (string.IsNullOrWhiteSpace(root)) continue;
                foreach (var relative in platform.RelativePaths)
                {
                    try
                    {
                        var candidate = Path.Combine(root, relative);
                        if (File.Exists(candidate)) return candidate;
                    }
                    catch
                    {
                        // ignore invalid paths
                    }
                }
            }
        }

        return null;
    }

    private static bool TryStart(string command)
    {
        try
        {
            var info = new ProcessStartInfo(command)
            {
                UseShellExecute = true,
            };
            using var process = Process.Start(info);
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"启动失败（{command}）：{ex.Message}");
            return false;
        }
    }
}

public static class SystemSettings
{
    public static void OpenMicrophonePrivacy() => Open("ms-settings:privacy-microphone");
    public static void OpenSoundSettings() => Open("ms-settings:sound");

    private static void Open(string uri)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"无法打开系统设置（{uri}）：{ex.Message}");
        }
    }
}
