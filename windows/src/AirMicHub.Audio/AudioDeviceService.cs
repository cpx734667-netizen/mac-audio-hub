using NAudio.CoreAudioApi;
using NAudio.Wave;
using AirMicHub.Core;

namespace AirMicHub.Audio;

public enum AudioDeviceKind
{
    Render,
    Capture,
}

public sealed record AudioDeviceInfo(
    string Id,
    string Name,
    bool IsDefault,
    AudioDeviceKind Kind,
    string State)
{
    public string DisplayName => IsDefault ? $"系统默认 · {Name}" : Name;
}

public sealed record AudioFormatInfo(
    int SampleRate,
    int Channels,
    int BitsPerSample,
    bool IsFloat,
    int StreamLatencyMilliseconds);

/// <summary>
/// WASAPI endpoint enumeration. Every call creates a short-lived enumerator because the
/// COM object is apartment-bound and enumeration happens from both UI and audio threads.
/// </summary>
public sealed class AudioDeviceService
{
    public IReadOnlyList<AudioDeviceInfo> GetRenderDevices() => GetDevices(DataFlow.Render);
    public IReadOnlyList<AudioDeviceInfo> GetCaptureDevices() => GetDevices(DataFlow.Capture);

    public IReadOnlyList<AudioDeviceInfo> GetDevices(DataFlow flow)
    {
        var results = new List<AudioDeviceInfo>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var defaultId = TryGetDefaultId(enumerator, flow);
            var collection = enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active);
            foreach (var device in collection)
            {
                try
                {
                    var id = device.ID;
                    results.Add(new AudioDeviceInfo(
                        id,
                        SafeName(device),
                        string.Equals(id, defaultId, StringComparison.OrdinalIgnoreCase),
                        flow == DataFlow.Render ? AudioDeviceKind.Render : AudioDeviceKind.Capture,
                        device.State.ToString()));
                }
                finally
                {
                    device.Dispose();
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"枚举音频设备失败（{flow}）：{ex.Message}");
        }

        return results
            .OrderByDescending(device => device.IsDefault)
            .ThenBy(device => device.Name, StringComparer.CurrentCulture)
            .ToList();
    }

    public string? GetDefaultRenderDeviceId() => GetDefaultId(DataFlow.Render);
    public string? GetDefaultCaptureDeviceId() => GetDefaultId(DataFlow.Capture);

    public string? GetDefaultId(DataFlow flow)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            return TryGetDefaultId(enumerator, flow);
        }
        catch (Exception ex)
        {
            Log.Warn($"读取默认音频设备失败：{ex.Message}");
            return null;
        }
    }

    public string GetDeviceName(string? deviceId, AudioDeviceKind kind)
    {
        var devices = kind == AudioDeviceKind.Render ? GetRenderDevices() : GetCaptureDevices();
        var match = devices.FirstOrDefault(device =>
            deviceId is not null && string.Equals(device.Id, deviceId, StringComparison.OrdinalIgnoreCase));
        if (match is not null) return match.Name;
        var defaultDevice = devices.FirstOrDefault(device => device.IsDefault);
        if (defaultDevice is not null) return defaultDevice.Name;
        return kind == AudioDeviceKind.Render ? "未找到输出设备" : "未找到输入设备";
    }

    public AudioFormatInfo? GetRenderFormat(string? deviceId = null)
    {
        try
        {
            using var device = OpenDevice(deviceId, DataFlow.Render);
            if (device is null) return null;
            var format = device.AudioClient.MixFormat;
            var latency = 0;
            try
            {
                latency = (int)Math.Round(device.AudioClient.StreamLatency / 10_000.0); // 100ns -> ms
            }
            catch
            {
                // StreamLatency requires an initialized client on some drivers.
            }
            return new AudioFormatInfo(
                format.SampleRate,
                format.Channels,
                format.BitsPerSample,
                WaveFormatInfo.IsFloat(format),
                Math.Clamp(latency, 0, 500));
        }
        catch (Exception ex)
        {
            Log.Warn($"读取输出设备格式失败：{ex.Message}");
            return null;
        }
    }

    public MMDevice? OpenDevice(string? deviceId, DataFlow flow)
    {
        using var enumerator = new MMDeviceEnumerator();
        try
        {
            if (!string.IsNullOrWhiteSpace(deviceId))
            {
                var device = enumerator.GetDevice(deviceId);
                if (device is not null && device.State == DeviceState.Active) return device;
                device?.Dispose();
            }
        }
        catch (Exception)
        {
            // Fall through to the default endpoint; a stale saved id should never be fatal.
        }

        try
        {
            return enumerator.GetDefaultAudioEndpoint(flow, Role.Multimedia);
        }
        catch (Exception ex)
        {
            Log.Warn($"没有可用的默认 {(flow == DataFlow.Render ? "输出" : "输入")} 设备：{ex.Message}");
            return null;
        }
    }

    public bool DeviceExists(string deviceId, DataFlow flow)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDevice(deviceId);
            return device is not null && device.State == DeviceState.Active;
        }
        catch
        {
            return false;
        }
    }

    private static string? TryGetDefaultId(MMDeviceEnumerator enumerator, DataFlow flow)
    {
        try
        {
            using var device = enumerator.GetDefaultAudioEndpoint(flow, Role.Multimedia);
            return device?.ID;
        }
        catch
        {
            return null;
        }
    }

    private static string SafeName(MMDevice device)
    {
        try
        {
            var name = device.FriendlyName;
            return string.IsNullOrWhiteSpace(name) ? "未命名设备" : name.Trim();
        }
        catch
        {
            return "未命名设备";
        }
    }
}
