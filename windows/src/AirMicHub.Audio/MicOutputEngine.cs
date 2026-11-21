using System.Buffers.Binary;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using AirMicHub.Core;
using AirMicHub.Core.Audio;

namespace AirMicHub.Audio;

/// <summary>
/// Pulls the 48 kHz stereo mix from <see cref="MixEngine"/> and renders it on the selected
/// WASAPI endpoint. The provider matches the device mix format exactly, resampling when the
/// endpoint is not 48 kHz. A 20 ms WASAPI buffer keeps monitoring latency low while still
/// tolerating Wi-Fi jitter.
/// </summary>
public sealed class MicOutputEngine : IDisposable
{
    private readonly MixEngine _mix;
    private readonly AudioDeviceService _devices;
    private readonly object _gate = new();
    private readonly System.Threading.Timer _watchdog;

    private WasapiOut? _output;
    private MMDevice? _device;
    private MixWaveProvider? _provider;
    private string? _deviceId;
    private bool _running;
    private bool _stopping;
    private bool _restartPending;
    private string? _error;
    private int _latencyMilliseconds = 25;

    public MicOutputEngine(MixEngine mix, AudioDeviceService devices)
    {
        _mix = mix;
        _devices = devices;
        _watchdog = new System.Threading.Timer(_ => WatchdogTick(), null, 3000, 3000);
    }

    public bool IsRunning { get { lock (_gate) return _running; } }
    public string? Error { get { lock (_gate) return _error; } }
    public string? DeviceId { get { lock (_gate) return _deviceId; } }
    public int LatencyMilliseconds { get { lock (_gate) return _latencyMilliseconds; } }

    public event Action? StateChanged;

    public void Start(string? deviceId)
    {
        lock (_gate)
        {
            StartLocked(deviceId);
        }
        StateChanged?.Invoke();
    }

    public void SwitchDevice(string? deviceId)
    {
        lock (_gate)
        {
            StopLocked();
            StartLocked(deviceId);
        }
        StateChanged?.Invoke();
    }

    public void Stop()
    {
        lock (_gate)
        {
            StopLocked();
        }
        StateChanged?.Invoke();
    }

    public void PlayTestTone()
    {
        lock (_gate)
        {
            if (!_running) StartLocked(_deviceId);
            _mix.TriggerTestTone();
        }
        StateChanged?.Invoke();
    }

    private void StartLocked(string? deviceId)
    {
        if (_running) return;
        _error = null;
        _restartPending = false;
        _stopping = false;

        MMDevice? device = null;
        WasapiOut? output = null;
        try
        {
            device = _devices.OpenDevice(deviceId, DataFlow.Render);
            if (device is null)
            {
                SetError("没有可用的输出设备。请先在 Windows 设置中连接扬声器或耳机。");
                return;
            }

            var format = device.AudioClient.MixFormat;
            var provider = new MixWaveProvider(_mix, format);
            output = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 20);
            output.Init(provider);
            output.PlaybackStopped += OnPlaybackStopped;
            output.Play();

            // StreamLatency is only valid once the audio client has been initialized; reading it
            // before Play() returns AUDCLNT_E_UNSUPPORTED_FORMAT on some drivers. Fall back to
            // our requested buffer plus one typical 10 ms device period.
            var streamLatency = 0;
            try
            {
                streamLatency = (int)Math.Round(device.AudioClient.StreamLatency / 10_000.0);
            }
            catch (Exception ex)
            {
                Log.Debug($"读取输出流延迟失败，使用估算值：0x{ex.HResult:X8}");
            }
            var estimatedLatency = streamLatency > 0 ? streamLatency + 20 : 30;

            _device = device;
            device = null;
            _provider = provider;
            _output = output;
            output = null;
            _deviceId = deviceId;
            _running = true;
            _latencyMilliseconds = Math.Clamp(estimatedLatency, 20, 250);

            _mix.SetEngineRunning(true);
            _mix.SetOutputLatencyMilliseconds(_latencyMilliseconds);
            Log.Info($"监听输出已启动：{SafeName(_device)} @ {format.SampleRate} Hz / {format.BitsPerSample} bit，" +
                     $"设备延迟约 {_latencyMilliseconds} ms");
        }
        catch (Exception ex)
        {
            SetError($"无法启动监听输出：{ex.Message}");
            Log.Error("启动监听输出失败", ex);
            try
            {
                if (output is not null) output.PlaybackStopped -= OnPlaybackStopped;
            }
            catch { }
            try { output?.Dispose(); } catch { }
            try { device?.Dispose(); } catch { }
            StopLocked();
        }
    }

    private void StopLocked()
    {
        _stopping = true;
        try
        {
            if (_output is not null)
            {
                _output.PlaybackStopped -= OnPlaybackStopped;
                try { _output.Stop(); } catch { /* already stopped */ }
                _output.Dispose();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"停止监听输出时出错：{ex.Message}");
        }
        finally
        {
            _output = null;
            _provider = null;
            try { _device?.Dispose(); } catch { }
            _device = null;
            if (_running)
            {
                Log.Info("监听输出已停止。");
            }
            _running = false;
            _mix.SetEngineRunning(false);
            _stopping = false;
            _restartPending = false;
        }
    }

    private void OnPlaybackStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            Log.Error("监听输出异常停止", args.Exception);
        }

        lock (_gate)
        {
            if (_stopping) return;
            _restartPending = true;
            if (args.Exception is not null)
            {
                SetError($"监听输出中断：{args.Exception.Message}");
            }
            else
            {
                _error ??= "监听输出意外停止，正在尝试恢复。";
            }
            _running = false;
            _mix.SetEngineRunning(false);
        }
        StateChanged?.Invoke();
    }

    private void WatchdogTick()
    {
        var changed = false;
        try
        {
            lock (_gate)
            {
                if (_restartPending && !_stopping)
                {
                    Log.Warn("监听输出意外停止，正在尝试用系统默认设备恢复。");
                    StopLocked();
                    StartLocked(null);
                    if (_running)
                    {
                        _error = "监听输出曾中断，已自动恢复到系统默认输出。";
                    }
                    else if (_error is null)
                    {
                        _error = "监听输出已停止，且无法自动恢复。请重新选择输出设备。";
                    }
                    changed = true;
                    return;
                }

                if (!_running || _output is null || _deviceId is null) return;
                if (_devices.DeviceExists(_deviceId, DataFlow.Render)) return;

                Log.Warn("所选输出设备已断开，回退到系统默认输出。");
                StopLocked();
                StartLocked(null);
                if (_running)
                {
                    _error = "所选输出设备已断开，已自动切换回系统默认输出。";
                }
                else if (_error is null)
                {
                    _error = "所选输出设备已断开，且无法切换回系统默认输出。";
                }
                changed = true;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"输出设备监视失败：{ex.Message}");
        }

        if (changed) StateChanged?.Invoke();
    }

    private void SetError(string message)
    {
        _error = message;
        Log.Warn(message);
    }

    private static string SafeName(MMDevice device)
    {
        try { return device.FriendlyName ?? "默认输出"; }
        catch { return "默认输出"; }
    }

    public void Dispose()
    {
        _watchdog.Dispose();
        lock (_gate)
        {
            StopLocked();
        }
    }
}

/// <summary>
/// IWaveProvider that converts the 48 kHz float mix to the endpoint's exact mix format.
/// The hot path uses preallocated scratch buffers only.
/// </summary>
internal sealed class MixWaveProvider : IWaveProvider
{
    private readonly MixEngine _mix;
    private readonly int _channels;
    private readonly int _bytesPerSample;
    private readonly bool _isFloat;
    private readonly bool _isPcm;
    private readonly StreamingResampler? _resampler;
    private float[] _mixScratch;
    private float[] _resampleScratch;
    private float[] _pending;
    private int _pendingFrames;
    private int _pendingRead;

    public MixWaveProvider(MixEngine mix, WaveFormat format)
    {
        _mix = mix;
        WaveFormat = format;
        _channels = Math.Max(1, format.Channels);
        _bytesPerSample = Math.Max(1, format.BitsPerSample / 8);
        _isFloat = WaveFormatInfo.IsFloat(format);
        _isPcm = WaveFormatInfo.IsPcm(format);
        _resampler = format.SampleRate == MixEngine.SampleRate
            ? null
            : new StreamingResampler(MixEngine.SampleRate, format.SampleRate, _channels);
        _mixScratch = new float[4096 * 2];
        _resampleScratch = new float[4096 * Math.Max(1, _channels)];
        _pending = new float[8192 * _channels];
    }

    public WaveFormat WaveFormat { get; }

    public int Read(byte[] buffer, int offset, int count)
    {
        var frames = count / WaveFormat.BlockAlign;
        if (frames <= 0) return 0;

        EnsurePending(frames);

        var read = 0;
        for (var frame = 0; frame < frames; frame++)
        {
            var source = (_pendingRead + frame) * _channels;
            for (var channel = 0; channel < _channels; channel++)
            {
                WriteSample(buffer, offset + read, _pending[source + channel]);
                read += _bytesPerSample;
            }
        }

        _pendingRead += frames;
        if (_pendingRead >= _pendingFrames)
        {
            _pendingRead = 0;
            _pendingFrames = 0;
        }
        else if (_pendingRead > 8192)
        {
            var remaining = _pendingFrames - _pendingRead;
            Array.Copy(_pending, _pendingRead * _channels, _pending, 0, remaining * _channels);
            _pendingFrames = remaining;
            _pendingRead = 0;
        }

        return read;
    }

    private void EnsurePending(int framesNeeded)
    {
        var guard = 0;
        while (_pendingFrames - _pendingRead < framesNeeded && guard++ < 64)
        {
            var chunkFrames = 240; // 5 ms of output
            var inputNeeded = _resampler is null
                ? chunkFrames
                : (int)Math.Ceiling(chunkFrames * _resampler.Ratio) + 4;

            if (_mixScratch.Length < inputNeeded * 2)
            {
                Array.Resize(ref _mixScratch, inputNeeded * 2);
            }

            // MixEngine always produces stereo; map that onto the endpoint channel count.
            _mix.Read(_mixScratch.AsSpan(0, inputNeeded * 2), inputNeeded);
            var mixBuffer = _mixScratch.AsSpan(0, inputNeeded * 2);

            if (_resampler is null)
            {
                var framesToAppend = Math.Min(chunkFrames, inputNeeded);
                EnsureCapacity(_pendingFrames + framesToAppend);
                for (var frame = 0; frame < framesToAppend; frame++)
                {
                    for (var channel = 0; channel < _channels; channel++)
                    {
                        _pending[(_pendingFrames + frame) * _channels + channel] =
                            mixBuffer[frame * 2 + Math.Min(channel, 1)];
                    }
                }
                _pendingFrames += framesToAppend;
            }
            else
            {
                var capacity = chunkFrames + 16;
                if (_resampleScratch.Length < capacity * _channels)
                {
                    Array.Resize(ref _resampleScratch, capacity * _channels);
                }
                var produced = _resampler.Process(mixBuffer, inputNeeded, _resampleScratch, capacity);
                EnsureCapacity(_pendingFrames + produced);
                Array.Copy(_resampleScratch, 0, _pending, _pendingFrames * _channels, produced * _channels);
                _pendingFrames += produced;

                if (produced == 0) break;
            }
        }
    }

    private void EnsureCapacity(int frames)
    {
        var required = frames * _channels;
        if (_pending.Length >= required) return;
        var size = _pending.Length;
        while (size < required) size *= 2;
        Array.Resize(ref _pending, size);
    }

    private void WriteSample(byte[] buffer, int offset, float value)
    {
        if (_isFloat)
        {
            if (_bytesPerSample == 4)
            {
                BinaryPrimitives.WriteSingleLittleEndian(buffer.AsSpan(offset, 4), value);
            }
            else if (_bytesPerSample == 8)
            {
                BinaryPrimitives.WriteDoubleLittleEndian(buffer.AsSpan(offset, 8), value);
            }
            return;
        }

        if (!_isPcm) return;

        switch (_bytesPerSample)
        {
            case 2:
                BinaryPrimitives.WriteInt16LittleEndian(
                    buffer.AsSpan(offset, 2),
                    (short)Math.Round(Math.Clamp(value, -1f, 1f) * (value < 0 ? 0x8000 : 0x7fff)));
                break;
            case 3:
            {
                var scaled = (int)Math.Round(Math.Clamp(value, -1f, 1f) * 8388607);
                buffer[offset] = (byte)(scaled & 0xFF);
                buffer[offset + 1] = (byte)((scaled >> 8) & 0xFF);
                buffer[offset + 2] = (byte)((scaled >> 16) & 0xFF);
                break;
            }
            case 4:
                BinaryPrimitives.WriteInt32LittleEndian(
                    buffer.AsSpan(offset, 4),
                    (int)Math.Round(Math.Clamp(value, -1f, 1f) * 2147483647.0));
                break;
        }
    }
}
