using NAudio.CoreAudioApi;
using NAudio.Wave;
using AirMicHub.Core;
using AirMicHub.Core.Audio;

namespace AirMicHub.Audio;

/// <summary>
/// Local Windows microphone (USB / headset / sound card) feeding the same mixer as the
/// phones. The capture device reports whatever format it likes; everything is normalized
/// to mono Float32 at its native rate and resampled by <see cref="MixEngine"/>.
/// </summary>
public sealed class SystemMicSource : IDisposable
{
    private readonly MixEngine _mix;
    private readonly AudioDeviceService _devices;
    private readonly object _gate = new();

    private WasapiCapture? _capture;
    private Guid _sourceId = Guid.Empty;
    private string? _error;
    private string _deviceName = "本机麦克风";
    private bool _active;

    public SystemMicSource(MixEngine mix, AudioDeviceService devices)
    {
        _mix = mix;
        _devices = devices;
    }

    public bool IsActive { get { lock (_gate) return _active; } }
    public string? Error { get { lock (_gate) return _error; } }
    public string DeviceName { get { lock (_gate) return _deviceName; } }
    public long FramesCaptured => Interlocked.Read(ref _framesCaptured);

    private long _framesCaptured;

    public event Action? StateChanged;

    public Guid Start(string? deviceId)
    {
        lock (_gate)
        {
            StopLocked();
            _error = null;
            try
            {
                var device = _devices.OpenDevice(deviceId, DataFlow.Capture);
                if (device is null)
                {
                    _error = "没有可用的麦克风设备。请连接麦克风并在 Windows 隐私设置中允许麦克风访问。";
                    Log.Warn(_error);
                    return Guid.Empty;
                }

                _deviceName = SafeName(device);
                var capture = new WasapiCapture(device, useEventSync: true, audioBufferMillisecondsLength: 20);
                capture.ShareMode = AudioClientShareMode.Shared;
                var format = capture.WaveFormat;
                _sourceId = _mix.AddSource($"本机麦克风 · {_deviceName}", format.SampleRate, isLocalMic: true);

                capture.DataAvailable += OnDataAvailable;
                capture.RecordingStopped += OnRecordingStopped;
                capture.StartRecording();

                _capture = capture;
                _active = true;
                Log.Info($"本机麦克风已启动：{_deviceName} @ {format.SampleRate} Hz / {format.Channels} ch / " +
                         $"{format.BitsPerSample} bit");
            }
            catch (Exception ex)
            {
                _error = $"无法启动本机麦克风：{ex.Message}";
                Log.Error("启动本机麦克风失败", ex);
                StopLocked();
            }
        }

        StateChanged?.Invoke();
        return _sourceId;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        try
        {
            var capture = _capture;
            if (capture is null || _sourceId == Guid.Empty) return;
            var format = capture.WaveFormat;
            var mono = Pcm.DecodeToMonoFloat(
                new ReadOnlySpan<byte>(args.Buffer, 0, args.BytesRecorded),
                format.BitsPerSample,
                format.Encoding == WaveFormatEncoding.IeeeFloat,
                format.Channels);
            if (mono.Length == 0) return;
            Interlocked.Increment(ref _framesCaptured);
            _mix.Enqueue(_sourceId, mono, format.SampleRate);
        }
        catch (Exception ex)
        {
            Log.Warn($"处理本机麦克风数据失败：{ex.Message}");
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            lock (_gate)
            {
                _error = $"麦克风已停止：{args.Exception.Message}";
                _active = false;
                var sourceId = _sourceId;
                _sourceId = Guid.Empty;
                if (sourceId != Guid.Empty) _mix.RemoveSource(sourceId);
                Log.Error("本机麦克风异常停止", args.Exception);
            }
            StateChanged?.Invoke();
        }
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
        if (_capture is not null)
        {
            try
            {
                _capture.DataAvailable -= OnDataAvailable;
                _capture.RecordingStopped -= OnRecordingStopped;
                if (_capture.CaptureState == CaptureState.Capturing)
                {
                    _capture.StopRecording();
                }
                _capture.Dispose();
            }
            catch (Exception ex)
            {
                Log.Warn($"停止本机麦克风失败：{ex.Message}");
            }
        }

        _capture = null;
        if (_sourceId != Guid.Empty)
        {
            _mix.RemoveSource(_sourceId);
            _sourceId = Guid.Empty;
        }
        if (_active) Log.Info("本机麦克风已停止。");
        _active = false;
    }

    private static string SafeName(MMDevice device)
    {
        try { return device.FriendlyName ?? "麦克风"; }
        catch { return "麦克风"; }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            StopLocked();
        }
    }
}
