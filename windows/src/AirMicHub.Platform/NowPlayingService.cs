using AirMicHub.Core;

namespace AirMicHub.Platform;

public sealed record NowPlayingSnapshot(
    string Title,
    string Artist,
    string Album,
    bool IsPlaying,
    double PositionSeconds,
    double DurationSeconds,
    string SourceApp,
    DateTimeOffset UpdatedAt);

/// <summary>
/// Reads Windows "now playing" metadata through GSMTC (GlobalSystemMediaTransportControls).
/// Platform apps that do not publish a session simply produce null; the UI shows
/// "未检测到平台播放" instead of inventing data.
/// </summary>
public sealed class NowPlayingService : IAsyncDisposable
{
    private readonly object _gate = new();
    private CancellationTokenSource? _cts;
    private Task? _pollTask;
    private NowPlayingSnapshot? _current;
    private string? _error;

    public NowPlayingSnapshot? Current { get { lock (_gate) return _current; } }
    public string? Error { get { lock (_gate) return _error; } }
    public bool Available { get; private set; }

    public event Action? Changed;

    public async Task StartAsync()
    {
        try
        {
            var manager = await Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            Manager = manager;
            manager.CurrentSessionChanged += (_, _) => Changed?.Invoke();
            Available = true;
            _cts = new CancellationTokenSource();
            _pollTask = Task.Run(() => PollLoopAsync(_cts.Token));
            Log.Info("GSMTC 已启动，开始读取系统 Now Playing。");
        }
        catch (Exception ex)
        {
            _error = $"无法读取系统正在播放的信息：{ex.Message}";
            Log.Warn(_error);
        }
    }

    private Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager? Manager { get; set; }

    private async Task PollLoopAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try
        {
            while (await timer.WaitForNextTickAsync(token))
            {
                await RefreshAsync();
            }
        }
        catch (OperationCanceledException)
        {
            // shutting down
        }
    }

    private async Task RefreshAsync()
    {
        try
        {
            var manager = Manager;
            var session = manager?.GetCurrentSession();
            if (session is null)
            {
                SetCurrent(null);
                return;
            }

            var props = await session.TryGetMediaPropertiesAsync();
            var playback = session.GetPlaybackInfo();
            var timeline = session.GetTimelineProperties();
            var playing = playback?.PlaybackStatus ==
                          Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;

            var title = props?.Title?.Trim() ?? string.Empty;
            var artist = props?.Artist?.Trim() ?? string.Empty;
            var album = props?.AlbumTitle?.Trim() ?? string.Empty;
            if (title.Length == 0)
            {
                SetCurrent(null);
                return;
            }

            var duration = Math.Max(0, timeline.EndTime.TotalSeconds - timeline.StartTime.TotalSeconds);
            var position = Math.Max(0, timeline.Position.TotalSeconds - timeline.StartTime.TotalSeconds);
            var snapshot = new NowPlayingSnapshot(
                title,
                artist,
                album,
                playing,
                position,
                duration,
                session.SourceAppUserModelId ?? string.Empty,
                DateTimeOffset.Now);
            SetCurrent(snapshot);
        }
        catch (Exception ex)
        {
            var message = ex.Message;
            lock (_gate)
            {
                _error = $"读取系统播放信息失败：{message}";
            }
        }
    }

    private void SetCurrent(NowPlayingSnapshot? snapshot)
    {
        bool changed;
        lock (_gate)
        {
            var previous = _current;
            changed = (previous is null) != (snapshot is null) ||
                      (previous is not null && snapshot is not null &&
                       (previous.Title != snapshot.Title ||
                        previous.Artist != snapshot.Artist ||
                        previous.IsPlaying != snapshot.IsPlaying));
            _current = snapshot;
        }
        if (changed) Changed?.Invoke();
    }

    public async Task<bool> TogglePlayPauseAsync()
    {
        try
        {
            var session = Manager?.GetCurrentSession();
            if (session is null) return false;
            return await session.TryTogglePlayPauseAsync();
        }
        catch (Exception ex)
        {
            Log.Warn($"切换播放状态失败：{ex.Message}");
            return false;
        }
    }

    public async Task<bool> NextAsync()
    {
        try
        {
            var session = Manager?.GetCurrentSession();
            return session is not null && await session.TrySkipNextAsync();
        }
        catch (Exception ex)
        {
            Log.Warn($"下一首失败：{ex.Message}");
            return false;
        }
    }

    public async Task<bool> PreviousAsync()
    {
        try
        {
            var session = Manager?.GetCurrentSession();
            return session is not null && await session.TrySkipPreviousAsync();
        }
        catch (Exception ex)
        {
            Log.Warn($"上一首失败：{ex.Message}");
            return false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        if (_pollTask is not null)
        {
            try { await _pollTask; } catch { }
        }
        Manager = null;
        _cts?.Dispose();
    }
}
