namespace AirMicHub.Core.Audio;

public sealed record MixSourceSnapshot(
    Guid Id,
    string Name,
    float Level,
    double QueueMilliseconds,
    bool Muted,
    bool Primed,
    double InputRate,
    bool IsLocalMic,
    long DroppedFrames);

public sealed record MixSnapshot(
    double SampleRate,
    double QueueMilliseconds,
    double BufferMilliseconds,
    double OutputLatencyMilliseconds,
    int Underruns,
    long SilentChunks,
    long DroppedFrames,
    float Level,
    float Volume,
    bool EngineRunning,
    bool TestTonePlaying,
    IReadOnlyList<MixSourceSnapshot> Sources);

/// <summary>
/// The heart of the 8765 path: any number of mono microphone streams, each with its own
/// adaptive queue, resampled to 48 kHz and mixed into one stereo Float32 stream.
///
/// Deliberately pull-based. The WASAPI output thread calls <see cref="Read"/> in 5 ms
/// chunks; there is no producer timer whose drift can accumulate into latency. Sources
/// buffer 10 ms before they are allowed to play and hard-trim at 30 ms so a congested
/// phone can never push the mix minutes behind.
/// </summary>
public sealed class MixEngine
{
    public const int SampleRate = 48_000;
    public const int ChunkFrames = 240; // 5 ms at 48 kHz
    public const int DefaultPrebufferFrames = 480; // 10 ms
    public const int DefaultMaxQueueFrames = 1_440; // 30 ms

    private sealed class Source
    {
        public required Guid Id { get; init; }
        public required string Name { get; set; }
        public double InputRate { get; set; }
        public StreamingResampler? Resampler { get; set; }
        public List<float> Samples { get; } = new(4096);
        public int ReadIndex { get; set; }
        public int PrebufferFrames { get; set; } = DefaultPrebufferFrames;
        public int MaxQueueFrames { get; set; } = DefaultMaxQueueFrames;
        public float Level { get; set; }
        public DateTime LastDataAt { get; set; } = DateTime.MinValue;
        public bool Muted { get; set; }
        public bool Primed { get; set; }
        public bool IsLocalMic { get; init; }
        public long DroppedFrames { get; set; }

        public int Available => Samples.Count - ReadIndex;

        public double QueueMilliseconds => Available * 1000.0 / SampleRate;
    }

    private readonly object _gate = new();
    private readonly Dictionary<Guid, Source> _sources = new();
    private readonly float[] _chunkScratch = new float[ChunkFrames];
    private float[] _resampleScratch = new float[8192];

    private float _volume = 0.9f;
    private float _aggregateLevel;
    private int _outputLatencyMilliseconds = 25;
    private int _underruns;
    private long _silentChunks;
    private bool _engineRunning;
    private float[]? _testTone;
    private int _testTonePosition;
    private DateTime _lastReadAt = DateTime.UtcNow;

    public Guid AddSource(
        string name,
        double inputRate,
        bool isLocalMic = false,
        int prebufferMilliseconds = 10,
        int maxQueueMilliseconds = 30,
        Guid? id = null)
    {
        var sourceId = id ?? Guid.NewGuid();
        lock (_gate)
        {
            var prebuffer = Math.Max(ChunkFrames, SampleRate * Math.Clamp(prebufferMilliseconds, 5, 200) / 1000);
            var maxQueue = Math.Max(prebuffer, SampleRate * Math.Clamp(maxQueueMilliseconds, 10, 500) / 1000);
            if (_sources.TryGetValue(sourceId, out var existing))
            {
                existing.Name = name;
                existing.PrebufferFrames = prebuffer;
                existing.MaxQueueFrames = maxQueue;
                if (Math.Abs(existing.InputRate - inputRate) > 0.5)
                {
                    // A reused id with a different native rate must not keep stale samples or a
                    // resampler configured for the old rate.
                    existing.Samples.Clear();
                    existing.ReadIndex = 0;
                    existing.Primed = false;
                    ApplyRate(existing, inputRate);
                }
            }
            else
            {
                _sources[sourceId] = new Source
                {
                    Id = sourceId,
                    Name = name,
                    InputRate = inputRate,
                    PrebufferFrames = prebuffer,
                    MaxQueueFrames = maxQueue,
                    IsLocalMic = isLocalMic,
                };
            }
        }
        return sourceId;
    }

    public bool RemoveSource(Guid id)
    {
        lock (_gate)
        {
            if (!_sources.Remove(id)) return false;
            if (_sources.Count == 0)
            {
                _aggregateLevel = 0;
                _underruns = 0;
                _silentChunks = 0;
            }
        }
        return true;
    }

    public bool ContainsSource(Guid id)
    {
        lock (_gate) return _sources.ContainsKey(id);
    }

    public void SetMuted(Guid id, bool muted)
    {
        lock (_gate)
        {
            if (_sources.TryGetValue(id, out var source)) source.Muted = muted;
        }
    }

    public IReadOnlyList<(Guid Id, string Name, bool IsLocalMic)> ListSources()
    {
        lock (_gate)
        {
            return _sources.Values.Select(s => (s.Id, s.Name, s.IsLocalMic)).ToList();
        }
    }

    public void SetInputRate(Guid id, double rate)
    {
        lock (_gate)
        {
            if (_sources.TryGetValue(id, out var source)) ApplyRate(source, rate);
        }
    }

    public void Enqueue(Guid id, ReadOnlySpan<byte> pcm16, double sampleRate)
    {
        var mono = Pcm.Int16ToFloat(pcm16);
        Enqueue(id, mono, sampleRate);
    }

    public void Enqueue(Guid id, ReadOnlySpan<float> mono, double sampleRate)
    {
        if (mono.Length == 0) return;
        lock (_gate)
        {
            if (!_sources.TryGetValue(id, out var source)) return;

            ApplyRate(source, sampleRate);

            var peak = Pcm.Peak(mono);
            var rms = Pcm.Rms(mono);
            var instant = Math.Max(rms * 1.8f, peak * 0.55f);
            source.Level = Math.Max(instant, source.Level * 0.74f);
            source.LastDataAt = DateTime.UtcNow;

            if (source.Resampler is null)
            {
                source.Samples.AddRange(mono.ToArray());
            }
            else
            {
                var capacity = (int)Math.Ceiling(mono.Length * (double)SampleRate / source.InputRate) + 8;
                if (capacity > _resampleScratch.Length)
                {
                    Array.Resize(ref _resampleScratch, capacity);
                }
                var written = source.Resampler.Process(mono, mono.Length, _resampleScratch, capacity);
                for (var i = 0; i < written; i++)
                {
                    source.Samples.Add(_resampleScratch[i]);
                }
            }

            Trim(source);
        }
    }

    /// <summary>
    /// Called from the WASAPI output thread. Writes exactly <paramref name="frames"/> stereo
    /// frames (silence when nothing is primed). Never blocks on network or UI work.
    /// </summary>
    public void Read(Span<float> stereo, int frames)
    {
        if (frames <= 0) return;
        lock (_gate)
        {
            var now = DateTime.UtcNow;
            var elapsedSeconds = Math.Max(0, (now - _lastReadAt).TotalSeconds);
            _lastReadAt = now;

            foreach (var source in _sources.Values)
            {
                if ((now - source.LastDataAt).TotalSeconds > 0.1)
                {
                    source.Level *= (float)Math.Pow(0.86, Math.Max(1, elapsedSeconds / 0.002));
                }
                if (source.Available >= source.PrebufferFrames) source.Primed = true;
                if (source.Available == 0 && (now - source.LastDataAt).TotalSeconds > 0.2) source.Primed = false;
            }

            var offsetFrames = 0;
            while (offsetFrames < frames)
            {
                var chunk = Math.Min(ChunkFrames, frames - offsetFrames);
                var usable = 0;
                var starved = false;
                foreach (var source in _sources.Values)
                {
                    if (source.Muted || !source.Primed) continue;
                    if (source.Available >= chunk) usable++;
                    else starved = true;
                }

                if (starved) _underruns++;
                if (usable == 0) _silentChunks++;

                _chunkScratch.AsSpan(0, chunk).Clear();
                if (usable > 0)
                {
                    var normalization = 1f / MathF.Sqrt(usable);
                    foreach (var source in _sources.Values)
                    {
                        if (source.Muted || !source.Primed || source.Available < chunk) continue;
                        for (var i = 0; i < chunk; i++)
                        {
                            _chunkScratch[i] += source.Samples[source.ReadIndex + i] * normalization;
                        }
                        source.ReadIndex += chunk;
                        Compact(source);
                    }
                }

                var peak = 0f;
                for (var i = 0; i < chunk; i++)
                {
                    var value = _chunkScratch[i];
                    if (_testTone is not null)
                    {
                        value += _testTone[_testTonePosition] * 0.9f;
                        if (++_testTonePosition >= _testTone.Length)
                        {
                            _testTone = null;
                            _testTonePosition = 0;
                        }
                    }
                    var abs = Math.Abs(value);
                    if (abs > peak) peak = abs;
                    value = Math.Clamp(value, -1f, 1f) * _volume;
                    var destination = (offsetFrames + i) * 2;
                    stereo[destination] = value;
                    stereo[destination + 1] = value;
                }

                if (peak > _aggregateLevel) _aggregateLevel = peak;
                offsetFrames += chunk;
            }

            _aggregateLevel = Math.Max(_aggregateLevel * 0.90f, 0f);
        }
    }

    public void TriggerTestTone()
    {
        var tone = new float[SampleRate * 65 / 100]; // 650 ms
        const double frequency = 660;
        var duration = tone.Length / (double)SampleRate;
        for (var i = 0; i < tone.Length; i++)
        {
            var t = i / (double)SampleRate;
            var envelope = Math.Min(1.0, t / 0.02) * Math.Min(1.0, (duration - t) / 0.12);
            tone[i] = (float)(Math.Sin(2 * Math.PI * frequency * t) * 0.28 * envelope);
        }
        lock (_gate)
        {
            _testTone = tone;
            _testTonePosition = 0;
        }
        Log.Info("已触发测试音（660 Hz）");
    }

    public bool TestTonePlaying
    {
        get { lock (_gate) return _testTone is not null; }
    }

    public void SetVolume(float value)
    {
        lock (_gate) _volume = Math.Clamp(value, 0f, 1f);
    }

    public float Volume
    {
        get { lock (_gate) return _volume; }
    }

    public void SetOutputLatencyMilliseconds(int value)
    {
        lock (_gate) _outputLatencyMilliseconds = Math.Clamp(value, 0, 500);
    }

    public void SetEngineRunning(bool running)
    {
        lock (_gate) _engineRunning = running;
    }

    public void Reset()
    {
        lock (_gate)
        {
            _sources.Clear();
            _aggregateLevel = 0;
            _underruns = 0;
            _silentChunks = 0;
            _testTone = null;
            _testTonePosition = 0;
        }
    }

    public MixSnapshot Snapshot()
    {
        lock (_gate)
        {
            var queueFrames = 0;
            var list = new List<MixSourceSnapshot>(_sources.Count);
            var dropped = 0L;
            foreach (var source in _sources.Values.OrderBy(source => source.Name, StringComparer.Ordinal))
            {
                queueFrames = Math.Max(queueFrames, source.Available);
                dropped += source.DroppedFrames;
                list.Add(new MixSourceSnapshot(
                    source.Id,
                    source.Name,
                    source.Level,
                    source.QueueMilliseconds,
                    source.Muted,
                    source.Primed,
                    source.InputRate,
                    source.IsLocalMic,
                    source.DroppedFrames));
            }

            var queueMs = queueFrames * 1000.0 / SampleRate;
            return new MixSnapshot(
                SampleRate,
                queueMs,
                queueMs + _outputLatencyMilliseconds,
                _outputLatencyMilliseconds,
                _underruns,
                _silentChunks,
                dropped,
                _aggregateLevel,
                _volume,
                _engineRunning,
                _testTone is not null,
                list);
        }
    }

    private void ApplyRate(Source source, double rate)
    {
        if (rate < 8_000 || rate > 192_000) return;
        if (Math.Abs(source.InputRate - rate) < 0.5 && source.Resampler is not null) return;
        if (Math.Abs(rate - SampleRate) < 0.5)
        {
            source.InputRate = SampleRate;
            source.Resampler = null;
            return;
        }
        source.InputRate = rate;
        source.Resampler = new StreamingResampler((int)Math.Round(rate), SampleRate, 1);
    }

    private void Trim(Source source)
    {
        var available = source.Available;
        if (available <= source.MaxQueueFrames) return;
        var drop = available - source.MaxQueueFrames;
        source.ReadIndex += drop;
        source.DroppedFrames += drop;
        Compact(source);
    }

    private static void Compact(Source source)
    {
        if (source.ReadIndex > 8_192 && source.ReadIndex > source.Samples.Count / 2)
        {
            source.Samples.RemoveRange(0, source.ReadIndex);
            source.ReadIndex = 0;
        }
    }
}
