using NAudio.CoreAudioApi;
using NAudio.Wave;
using AirMicHub.Core;
using AirMicHub.Core.Audio;

namespace AirMicHub.Audio;

/// <summary>
/// Captures what Windows is playing and normalizes it to 48 kHz stereo Float32, ready for
/// the 8787 broadcast. Prefers process loopback with the AirMic Hub process tree excluded so
/// the app's own vocal monitor never echoes back to phones; falls back to a normal default-
/// device loopback and reports the downgrade instead of pretending it worked.
/// </summary>
public sealed class LoopbackCaptureService : IDisposable
{
    private readonly object _gate = new();
    private readonly int _sampleRate = MixEngine.SampleRate;

    private WasapiLoopbackCapture? _deviceCapture;
    private ProcessLoopbackCapture? _processCapture;
    private StreamingResampler? _resampler;
    private float[] _resampleScratch = new float[48_000 * 2];
    private bool _capturing;
    private string _mode = "none";
    private string? _error;

    public event Action<float[]>? AudioAvailable;
    public event Action? StateChanged;
    public event Action<string>? ErrorChanged;

    public bool IsCapturing { get { lock (_gate) return _capturing; } }
    public string Mode { get { lock (_gate) return _mode; } }
    public string? Error { get { lock (_gate) return _error; } }
    public bool ExcludesOwnAudio => string.Equals(Mode, "process", StringComparison.Ordinal);

    /// <summary>Starts capture. <paramref name="requestedMode"/> is "auto", "process" or "loopback".</summary>
    public void Start(string requestedMode = "auto")
    {
        lock (_gate)
        {
            StopLocked();
            _error = null;

            var preferredProcess = !string.Equals(requestedMode, "loopback", StringComparison.OrdinalIgnoreCase);
            if (preferredProcess)
            {
                try
                {
                    StartProcessLoopbackLocked();
                    return;
                }
                catch (Exception ex)
                {
                    var message = $"进程回环捕获不可用（{ex.Message}），已降级为默认输出设备回环捕获。" +
                                  "如果监听输出和系统默认输出是同一设备，手机端可能会听到自己的人声。";
                    Log.Warn(message);
                }
            }

            try
            {
                StartDeviceLoopbackLocked();
            }
            catch (Exception ex)
            {
                _error = $"系统音频捕获失败：{ex.Message}";
                Log.Error("启动系统音频捕获失败", ex);
                StopLocked();
                ErrorChanged?.Invoke(_error!);
                StateChanged?.Invoke();
                return;
            }

            // The fallback is a working configuration, not a failure: expose the downgrade
            // through Mode/health and keep the red error slot empty.
            _error = null;
            StateChanged?.Invoke();
        }
    }

    private void StartProcessLoopbackLocked()
    {
        var capture = new ProcessLoopbackCapture();
        capture.AudioAvailable += OnProcessAudio;
        capture.Start((uint)Environment.ProcessId);
        capture.Failed += ex =>
        {
            bool affected;
            lock (_gate)
            {
                affected = ReferenceEquals(_processCapture, capture);
                if (!affected) return;
                _capturing = false;
                _mode = "none";
                _error = $"进程回环捕获中断：{ex.Message}";
            }
            Log.Warn(_error);
            ErrorChanged?.Invoke(_error);
            StateChanged?.Invoke();
        };
        _processCapture = capture;
        _mode = "process";
        _capturing = true;
        _error = null;
        Log.Info("8787 系统音频捕获：进程回环（排除本应用）已开启。");
        StateChanged?.Invoke();
    }

    private void StartDeviceLoopbackLocked()
    {
        var capture = new WasapiLoopbackCapture();
        capture.DataAvailable += OnDeviceAudio;
        capture.RecordingStopped += OnDeviceRecordingStopped;
        var format = capture.WaveFormat;
        _resampler = format.SampleRate == _sampleRate
            ? null
            : new StreamingResampler(format.SampleRate, _sampleRate, 2);
        capture.StartRecording();

        _deviceCapture = capture;
        _mode = "loopback";
        _capturing = true;
        Log.Info($"8787 系统音频捕获：默认输出设备回环已开启（{format.SampleRate} Hz / " +
                 $"{format.Channels} ch / {format.BitsPerSample} bit）。");
        StateChanged?.Invoke();
    }

    private void OnProcessAudio(float[] samples)
    {
        if (samples.Length == 0) return;
        AudioAvailable?.Invoke(samples);
    }

    private void OnDeviceAudio(object? sender, WaveInEventArgs args)
    {
        try
        {
            var capture = _deviceCapture;
            if (capture is null || args.BytesRecorded <= 0) return;
            var format = capture.WaveFormat;
            var source = new ReadOnlySpan<byte>(args.Buffer, 0, args.BytesRecorded);

            var decoded = Pcm.DecodeInterleavedFloat(
                source,
                format.BitsPerSample,
                format.Encoding == WaveFormatEncoding.IeeeFloat);
            if (decoded.Length == 0) return;

            var channels = Math.Max(1, format.Channels);
            var frames = decoded.Length / channels;
            var interleaved = new float[frames * 2];
            for (var frame = 0; frame < frames; frame++)
            {
                var left = decoded[frame * channels];
                var right = channels > 1 ? decoded[frame * channels + 1] : left;
                interleaved[frame * 2] = left;
                interleaved[frame * 2 + 1] = right;
            }

            if (_resampler is null)
            {
                AudioAvailable?.Invoke(interleaved);
            }
            else
            {
                var capacity = (int)Math.Ceiling(interleaved.Length / 2.0 *
                                                 (double)_sampleRate / format.SampleRate) + 16;
                if (_resampleScratch.Length < capacity * 2) Array.Resize(ref _resampleScratch, capacity * 2);
                var produced = _resampler.Process(interleaved, interleaved.Length / 2, _resampleScratch, capacity);
                if (produced > 0)
                {
                    var output = new float[produced * 2];
                    Array.Copy(_resampleScratch, output, produced * 2);
                    AudioAvailable?.Invoke(output);
                }
            }
        }
        catch (Exception ex)
        {
            SetError($"处理系统音频失败：{ex.Message}");
        }
    }

    private void OnDeviceRecordingStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            SetError($"系统音频捕获已停止：{args.Exception.Message}");
            lock (_gate)
            {
                _capturing = false;
                _mode = "none";
            }
            StateChanged?.Invoke();
        }
    }

    private void SetError(string message)
    {
        lock (_gate)
        {
            _error = message;
        }
        Log.Warn(message);
        ErrorChanged?.Invoke(message);
    }

    public void Stop()
    {
        lock (_gate)
        {
            StopLocked();
        }
        StateChanged?.Invoke();
    }

    private void StopLocked()
    {
        if (_processCapture is not null)
        {
            try
            {
                _processCapture.AudioAvailable -= OnProcessAudio;
                _processCapture.Dispose();
            }
            catch (Exception ex)
            {
                Log.Warn($"停止进程回环捕获失败：{ex.Message}");
            }
            _processCapture = null;
        }

        if (_deviceCapture is not null)
        {
            try
            {
                _deviceCapture.DataAvailable -= OnDeviceAudio;
                _deviceCapture.RecordingStopped -= OnDeviceRecordingStopped;
                if (_deviceCapture.CaptureState == CaptureState.Capturing)
                {
                    _deviceCapture.StopRecording();
                }
                _deviceCapture.Dispose();
            }
            catch (Exception ex)
            {
                Log.Warn($"停止设备回环捕获失败：{ex.Message}");
            }
            _deviceCapture = null;
        }

        if (_capturing) Log.Info("8787 系统音频捕获已停止。");
        _capturing = false;
        _mode = "none";
        _resampler = null;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            StopLocked();
        }
    }
}
