using AirMicHub.Core;
using AirMicHub.Core.Lyrics;

namespace AirMicHub.Lyrics;

/// <summary>
/// Owns lyric lines, LRCLIB lookup and the ±0.5 s offset. The UI drives the clock (GSMTC
/// position when the platform exposes it, otherwise a local timer started by the user).
/// </summary>
public sealed class LyricsService
{
    private readonly ILyricsProvider _provider;
    private readonly Dictionary<string, List<LyricLine>> _cache = new(StringComparer.Ordinal);

    private string _currentKey = string.Empty;
    private int _requestVersion;

    public LyricsService(ILyricsProvider? provider = null)
    {
        _provider = provider ?? new LrclibClient();
    }

    public IReadOnlyList<LyricLine> Lines { get; private set; } = Array.Empty<LyricLine>();
    public string Status { get; private set; } = "先在音乐平台播放歌曲";
    public string Source { get; private set; } = string.Empty;
    public double OffsetSeconds { get; private set; }
    public string CurrentKey => _currentKey;

    public event Action? Changed;

    public async Task LoadForTrackAsync(
        string title,
        string artist,
        string album,
        double durationSeconds,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            _requestVersion++;
            SetState(Array.Empty<LyricLine>(), "先在音乐平台播放歌曲", string.Empty);
            _currentKey = string.Empty;
            return;
        }

        var key = $"{title.Trim()}|{artist.Trim()}";
        if (key == _currentKey && Lines.Count > 0) return;

        if (_cache.TryGetValue(key, out var cached))
        {
            _requestVersion++;
            _currentKey = key;
            SetState(cached, "歌词已同步", "LRCLIB");
            return;
        }

        var version = ++_requestVersion;
        _currentKey = key;
        SetState(Array.Empty<LyricLine>(), "正在匹配歌词…", string.Empty);
        try
        {
            var document = await _provider.GetAsync(title, artist, album, durationSeconds, cancellationToken);
            if (version != _requestVersion) return;
            document ??= await _provider.SearchAsync(title, artist, cancellationToken);
            if (version != _requestVersion) return;
            Apply(document, "LRCLIB", key, cache: true);
        }
        catch (Exception ex)
        {
            if (version != _requestVersion) return;
            Log.Warn($"自动匹配歌词失败：{ex.Message}");
            SetState(Array.Empty<LyricLine>(), "歌词服务不可用，可手动载入 LRC", string.Empty);
        }
    }

    public async Task<bool> SearchAsync(string title, string artist, CancellationToken cancellationToken = default)
    {
        var trimmed = title.Trim();
        if (trimmed.Length == 0)
        {
            _requestVersion++;
            SetState(Array.Empty<LyricLine>(), "请输入歌名", string.Empty);
            return false;
        }

        var version = ++_requestVersion;
        SetState(Array.Empty<LyricLine>(), "正在搜索歌词…", string.Empty);
        try
        {
            var document = await _provider.SearchAsync(trimmed, artist, cancellationToken);
            if (version != _requestVersion) return false;
            if (document is null || (string.IsNullOrWhiteSpace(document.SyncedLyrics) &&
                                     string.IsNullOrWhiteSpace(document.PlainLyrics)))
            {
                SetState(Array.Empty<LyricLine>(), "没有找到歌词", string.Empty);
                return false;
            }

            Apply(document, "LRCLIB 搜索", $"{trimmed}|{artist}", cache: false);
            return true;
        }
        catch (Exception ex)
        {
            if (version != _requestVersion) return false;
            Log.Warn($"搜索歌词失败：{ex.Message}");
            SetState(Array.Empty<LyricLine>(), "歌词服务不可用", string.Empty);
            return false;
        }
    }

    public bool LoadLrcText(string text, string sourceName)
    {
        _requestVersion++;
        OffsetSeconds = 0;
        var parsed = LrcParser.Parse(text);
        if (parsed.Count == 0)
        {
            SetState(LrcParser.PlainLines(text), "纯文本歌词（无法自动滚动）", sourceName);
            return false;
        }

        SetState(parsed, "已载入本地 LRC", sourceName);
        return true;
    }

    public bool LoadLrcFile(string path, out string? error)
    {
        error = null;
        try
        {
            var text = File.ReadAllText(path);
            LoadLrcText(text, Path.GetFileName(path));
            Log.Info($"已载入 LRC：{path}");
            return true;
        }
        catch (Exception ex)
        {
            error = $"无法读取 LRC 文件：{ex.Message}";
            Log.Warn(error);
            return false;
        }
    }

    public void SetOffset(double offset)
    {
        OffsetSeconds = Math.Clamp(offset, -30, 30);
        Changed?.Invoke();
    }

    public void AdjustOffset(double delta)
    {
        SetOffset(OffsetSeconds + Math.Clamp(delta, -1, 1));
    }

    public int CurrentIndex(double elapsedSeconds) => LrcParser.FindIndex(Lines, elapsedSeconds, OffsetSeconds);

    public void EnterIdle()
    {
        _requestVersion++;
        _currentKey = string.Empty;
        SetState(Array.Empty<LyricLine>(), "先在音乐平台播放歌曲", string.Empty);
    }

    private void Apply(LyricsDocument? document, string source, string cacheKey, bool cache)
    {
        if (document is null)
        {
            SetState(Array.Empty<LyricLine>(), "没有匹配到歌词，可手动载入 LRC", string.Empty);
            return;
        }

        var text = document.SyncedLyrics;
        var parsed = LrcParser.Parse(text);
        if (parsed.Count > 0)
        {
            if (cache) _cache[cacheKey] = parsed;
            SetState(parsed, "歌词已同步", source);
            return;
        }

        var plain = LrcParser.PlainLines(document.PlainLyrics);
        if (plain.Count > 0)
        {
            SetState(plain, "纯文本歌词（无法自动滚动）", source);
            return;
        }

        SetState(Array.Empty<LyricLine>(), "没有匹配到歌词，可手动载入 LRC", string.Empty);
    }

    private void SetState(IReadOnlyList<LyricLine> lines, string status, string source)
    {
        Lines = lines;
        Status = status;
        Source = source;
        Changed?.Invoke();
    }
}
