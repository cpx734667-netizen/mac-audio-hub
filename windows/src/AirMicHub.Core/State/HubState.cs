namespace AirMicHub.Core.State;

public sealed record MicPhoneStatus(
    Guid Id,
    int Channel,
    string Name,
    string Platform,
    string Address,
    float Level,
    double QueueMilliseconds,
    bool Muted,
    double Kbps);

public sealed record MicStatus(
    bool Listening,
    int Port,
    string? Error,
    IReadOnlyList<MicPhoneStatus> Phones,
    double BufferMilliseconds,
    double QueueMilliseconds,
    double OutputLatencyMilliseconds,
    double LatencyMilliseconds,
    double Kbps,
    int Underruns,
    long DroppedFrames,
    float Level,
    int SampleRate,
    string? OutputDeviceId,
    string OutputDeviceName,
    float Volume,
    bool LocalMicEnabled,
    bool LocalMicActive,
    string? LocalMicDeviceId,
    string LocalMicDeviceName,
    string? LocalMicError,
    bool TestTonePlaying,
    bool EngineRunning,
    string? OutputWarning);

public sealed record SpeakerDeviceStatus(
    Guid Id,
    string DeviceId,
    string Name,
    string Address,
    bool Active,
    DateTimeOffset ConnectedAt);

public sealed record SpeakerStatus(
    bool Listening,
    int Port,
    string? Error,
    bool CaptureEnabled,
    bool Capturing,
    string CaptureMode,
    string? CaptureError,
    bool Efficient,
    int SampleRate,
    int Channels,
    string Format,
    IReadOnlyList<SpeakerDeviceStatus> Devices,
    int ActiveCount,
    double BytesPerSecond,
    bool ExcludesOwnAudio,
    string? FeedbackWarning);

public sealed record NowPlayingStatus(
    string Title,
    string Artist,
    string Album,
    bool IsPlaying,
    double PositionSeconds,
    double DurationSeconds,
    string SourceApp);

public sealed record LyricLineStatus(double TimeSeconds, string Text);

public sealed record KaraokeStatus(
    NowPlayingStatus? NowPlaying,
    IReadOnlyList<LyricLineStatus> Lines,
    int CurrentLine,
    string LyricStatus,
    string LyricSource,
    double OffsetSeconds,
    bool ClockRunning,
    double ElapsedSeconds,
    string? LastError,
    string UnifiedOutputMessage);

public sealed record HubSnapshot(
    string ProductName,
    string Version,
    string? PrimaryAddress,
    IReadOnlyList<string> LanAddresses,
    string MicUrl,
    string SpeakerUrl,
    string? FatalError,
    MicStatus Mic,
    SpeakerStatus Speaker,
    KaraokeStatus Karaoke,
    DateTimeOffset UpdatedAt);

/// <summary>
/// Cross-thread status board. Audio/server threads write short snapshots; the WPF UI polls
/// <see cref="Snapshot"/> four times a second. Keeping the UI pull-based avoids marshalling
/// every meter tick onto the dispatcher.
/// </summary>
public sealed class HubState
{
    private readonly object _gate = new();
    private MicStatus _mic = new(
        false, 8765, null, Array.Empty<MicPhoneStatus>(), 0, 0, 0, 0, 0, 0, 0, 0, 48000,
        null, "系统默认输出", 0.9f, false, false, null, "本机麦克风", null, false, false, null);
    private SpeakerStatus _speaker = new(
        false, 8787, null, true, false, "idle", null, false, 48000, 2, "float32le",
        Array.Empty<SpeakerDeviceStatus>(), 0, 0, false, null);
    private KaraokeStatus _karaoke = new(
        null, Array.Empty<LyricLineStatus>(), -1, "先在音乐平台播放歌曲", string.Empty, 0, false, 0, null, string.Empty);
    private string? _primaryAddress;
    private string[] _lanAddresses = Array.Empty<string>();
    private string? _fatalError;

    public DateTimeOffset LastUpdated { get; private set; } = DateTimeOffset.Now;

    public void SetNetwork(string? primaryAddress, IEnumerable<string> addresses)
    {
        lock (_gate)
        {
            _primaryAddress = primaryAddress;
            _lanAddresses = addresses.ToArray();
            LastUpdated = DateTimeOffset.Now;
        }
    }

    public void SetFatalError(string? message)
    {
        lock (_gate)
        {
            _fatalError = message;
            LastUpdated = DateTimeOffset.Now;
        }
    }

    public void UpdateMic(Action<MicStateBuilder> update)
    {
        lock (_gate)
        {
            var builder = new MicStateBuilder(_mic);
            update(builder);
            _mic = builder.Build();
            LastUpdated = DateTimeOffset.Now;
        }
    }

    public void UpdateSpeaker(Action<SpeakerStateBuilder> update)
    {
        lock (_gate)
        {
            var builder = new SpeakerStateBuilder(_speaker);
            update(builder);
            _speaker = builder.Build();
            LastUpdated = DateTimeOffset.Now;
        }
    }

    public void UpdateKaraoke(Action<KaraokeStateBuilder> update)
    {
        lock (_gate)
        {
            var builder = new KaraokeStateBuilder(_karaoke);
            update(builder);
            _karaoke = builder.Build();
            LastUpdated = DateTimeOffset.Now;
        }
    }

    public HubSnapshot Snapshot()
    {
        lock (_gate)
        {
            var micPort = _mic.Port;
            var speakerPort = _speaker.Port;
            var address = _primaryAddress;
            var micUrl = address is null ? $"https://localhost:{micPort}/" : $"https://{address}:{micPort}/";
            var speakerUrl = address is null ? $"http://localhost:{speakerPort}/" : $"http://{address}:{speakerPort}/";
            return new HubSnapshot(
                BuildInfo.ProductName,
                BuildInfo.Version,
                address,
                _lanAddresses,
                micUrl,
                speakerUrl,
                _fatalError,
                _mic,
                _speaker,
                _karaoke,
                LastUpdated);
        }
    }
}

/// <summary>Mutable view used by <see cref="HubState.UpdateMic"/> so callers only touch changed fields.</summary>
public sealed class MicStateBuilder
{
    private MicStatus _source;

    internal MicStateBuilder(MicStatus source) => _source = source;

    public bool Listening { get => _source.Listening; set => _source = _source with { Listening = value }; }
    public int Port { get => _source.Port; set => _source = _source with { Port = value }; }
    public string? Error { get => _source.Error; set => _source = _source with { Error = value }; }
    public IReadOnlyList<MicPhoneStatus> Phones { get => _source.Phones; set => _source = _source with { Phones = value }; }
    public double BufferMilliseconds { get => _source.BufferMilliseconds; set => _source = _source with { BufferMilliseconds = value }; }
    public double QueueMilliseconds { get => _source.QueueMilliseconds; set => _source = _source with { QueueMilliseconds = value }; }
    public double OutputLatencyMilliseconds { get => _source.OutputLatencyMilliseconds; set => _source = _source with { OutputLatencyMilliseconds = value }; }
    public double LatencyMilliseconds { get => _source.LatencyMilliseconds; set => _source = _source with { LatencyMilliseconds = value }; }
    public double Kbps { get => _source.Kbps; set => _source = _source with { Kbps = value }; }
    public int Underruns { get => _source.Underruns; set => _source = _source with { Underruns = value }; }
    public long DroppedFrames { get => _source.DroppedFrames; set => _source = _source with { DroppedFrames = value }; }
    public float Level { get => _source.Level; set => _source = _source with { Level = value }; }
    public int SampleRate { get => _source.SampleRate; set => _source = _source with { SampleRate = value }; }
    public string? OutputDeviceId { get => _source.OutputDeviceId; set => _source = _source with { OutputDeviceId = value }; }
    public string OutputDeviceName { get => _source.OutputDeviceName; set => _source = _source with { OutputDeviceName = value }; }
    public float Volume { get => _source.Volume; set => _source = _source with { Volume = value }; }
    public bool LocalMicEnabled { get => _source.LocalMicEnabled; set => _source = _source with { LocalMicEnabled = value }; }
    public bool LocalMicActive { get => _source.LocalMicActive; set => _source = _source with { LocalMicActive = value }; }
    public string? LocalMicDeviceId { get => _source.LocalMicDeviceId; set => _source = _source with { LocalMicDeviceId = value }; }
    public string LocalMicDeviceName { get => _source.LocalMicDeviceName; set => _source = _source with { LocalMicDeviceName = value }; }
    public string? LocalMicError { get => _source.LocalMicError; set => _source = _source with { LocalMicError = value }; }
    public bool TestTonePlaying { get => _source.TestTonePlaying; set => _source = _source with { TestTonePlaying = value }; }
    public bool EngineRunning { get => _source.EngineRunning; set => _source = _source with { EngineRunning = value }; }
    public string? OutputWarning { get => _source.OutputWarning; set => _source = _source with { OutputWarning = value }; }

    internal MicStatus Build() => _source;
}

public sealed class SpeakerStateBuilder
{
    private SpeakerStatus _source;

    internal SpeakerStateBuilder(SpeakerStatus source) => _source = source;

    public bool Listening { get => _source.Listening; set => _source = _source with { Listening = value }; }
    public int Port { get => _source.Port; set => _source = _source with { Port = value }; }
    public string? Error { get => _source.Error; set => _source = _source with { Error = value }; }
    public bool CaptureEnabled { get => _source.CaptureEnabled; set => _source = _source with { CaptureEnabled = value }; }
    public bool Capturing { get => _source.Capturing; set => _source = _source with { Capturing = value }; }
    public string CaptureMode { get => _source.CaptureMode; set => _source = _source with { CaptureMode = value }; }
    public string? CaptureError { get => _source.CaptureError; set => _source = _source with { CaptureError = value }; }
    public bool Efficient { get => _source.Efficient; set => _source = _source with { Efficient = value }; }
    public int SampleRate { get => _source.SampleRate; set => _source = _source with { SampleRate = value }; }
    public int Channels { get => _source.Channels; set => _source = _source with { Channels = value }; }
    public string Format { get => _source.Format; set => _source = _source with { Format = value }; }
    public IReadOnlyList<SpeakerDeviceStatus> Devices { get => _source.Devices; set => _source = _source with { Devices = value }; }
    public int ActiveCount { get => _source.ActiveCount; set => _source = _source with { ActiveCount = value }; }
    public double BytesPerSecond { get => _source.BytesPerSecond; set => _source = _source with { BytesPerSecond = value }; }
    public bool ExcludesOwnAudio { get => _source.ExcludesOwnAudio; set => _source = _source with { ExcludesOwnAudio = value }; }
    public string? FeedbackWarning { get => _source.FeedbackWarning; set => _source = _source with { FeedbackWarning = value }; }

    internal SpeakerStatus Build() => _source;
}

public sealed class KaraokeStateBuilder
{
    private KaraokeStatus _source;

    internal KaraokeStateBuilder(KaraokeStatus source) => _source = source;

    public NowPlayingStatus? NowPlaying { get => _source.NowPlaying; set => _source = _source with { NowPlaying = value }; }
    public IReadOnlyList<LyricLineStatus> Lines { get => _source.Lines; set => _source = _source with { Lines = value }; }
    public int CurrentLine { get => _source.CurrentLine; set => _source = _source with { CurrentLine = value }; }
    public string LyricStatus { get => _source.LyricStatus; set => _source = _source with { LyricStatus = value }; }
    public string LyricSource { get => _source.LyricSource; set => _source = _source with { LyricSource = value }; }
    public double OffsetSeconds { get => _source.OffsetSeconds; set => _source = _source with { OffsetSeconds = value }; }
    public bool ClockRunning { get => _source.ClockRunning; set => _source = _source with { ClockRunning = value }; }
    public double ElapsedSeconds { get => _source.ElapsedSeconds; set => _source = _source with { ElapsedSeconds = value }; }
    public string? LastError { get => _source.LastError; set => _source = _source with { LastError = value }; }
    public string UnifiedOutputMessage { get => _source.UnifiedOutputMessage; set => _source = _source with { UnifiedOutputMessage = value }; }

    internal KaraokeStatus Build() => _source;
}
