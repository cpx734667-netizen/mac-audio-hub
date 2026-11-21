using System.Diagnostics;
using System.Text;

namespace AirMicHub.Core;

public enum LogLevel
{
    Debug,
    Info,
    Warn,
    Error,
}

/// <summary>
/// Minimal thread-safe logger. Writes to the debugger and to a rolling file under
/// %LOCALAPPDATA%\AirMicHub\logs. Audio callback threads must never block for long,
/// so failures are swallowed and the logger keeps a single short lock.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private static readonly string LogFilePath;
    private static bool _fileEnabled = true;
    private static bool _initialized;
    private static long _writtenBytes;

    static Log()
    {
        try
        {
            AppPaths.EnsureLogDirectory();
            LogFilePath = Path.Combine(AppPaths.LogDirectory, $"airmic-{DateTime.Now:yyyyMMdd}.log");
        }
        catch
        {
            LogFilePath = string.Empty;
            _fileEnabled = false;
        }
    }

    public static string? CurrentLogFile => string.IsNullOrEmpty(LogFilePath) ? null : LogFilePath;

    public static void Initialize()
    {
        if (_initialized) return;
        _initialized = true;
        Info($"==== AirMic Hub {BuildInfo.Version} 启动 (Windows {Environment.OSVersion.Version}) ====");
    }

    public static void Debug(string message) => Write(LogLevel.Debug, message);
    public static void Info(string message) => Write(LogLevel.Info, message);
    public static void Warn(string message) => Write(LogLevel.Warn, message);
    public static void Error(string message) => Write(LogLevel.Error, message);

    public static void Error(string message, Exception ex) =>
        Write(LogLevel.Error, $"{message} :: {ex.GetType().Name}: {ex.Message}");

    private static void Write(LogLevel level, string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} [{level.ToString().ToUpperInvariant(),-5}] {message}";
        System.Diagnostics.Debug.WriteLine(line);
        if (!_fileEnabled) return;

        try
        {
            lock (Gate)
            {
                if (_writtenBytes > 5 * 1024 * 1024 && !string.IsNullOrEmpty(LogFilePath))
                {
                    // Reset rather than grow without bound; users only need recent diagnostics.
                    File.WriteAllText(LogFilePath, string.Empty);
                    _writtenBytes = 0;
                }

                using var stream = new FileStream(LogFilePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                var bytes = Encoding.UTF8.GetBytes(line + Environment.NewLine);
                stream.Write(bytes);
                _writtenBytes += bytes.Length;
            }
        }
        catch
        {
            _fileEnabled = false;
        }
    }

    /// <summary>Removes log files older than seven days. Safe to call at startup.</summary>
    public static void CleanupOldLogs(int keepDays = 7)
    {
        try
        {
            if (!Directory.Exists(AppPaths.LogDirectory)) return;
            var cutoff = DateTime.Now.AddDays(-keepDays);
            foreach (var file in Directory.EnumerateFiles(AppPaths.LogDirectory, "airmic-*.log"))
            {
                if (File.GetLastWriteTime(file) < cutoff)
                {
                    File.Delete(file);
                }
            }
        }
        catch (Exception ex)
        {
            Debug($"清理日志失败：{ex.Message}");
        }
    }
}
