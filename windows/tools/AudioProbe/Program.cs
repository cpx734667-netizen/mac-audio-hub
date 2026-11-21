using System.Runtime.InteropServices;
using AirMicHub.Audio;
using NAudio.CoreAudioApi;
using NAudio.Wave;

Console.OutputEncoding = System.Text.Encoding.UTF8;

var service = new AudioDeviceService();
Console.WriteLine("=== Render devices ===");
foreach (var info in service.GetRenderDevices())
{
    Console.WriteLine($"- {(info.IsDefault ? "*" : " ")} {info.Name}  [{info.Id}]");
    try
    {
        using var device = service.OpenDevice(info.Id, DataFlow.Render);
        if (device is null) { Console.WriteLine("    open failed"); continue; }
        var format = device.AudioClient.MixFormat;
        Console.WriteLine($"    mix: {format.SampleRate} Hz, {format.Channels} ch, {format.BitsPerSample} bit, " +
                          $"{format.Encoding}, block={format.BlockAlign}, latency={device.AudioClient.StreamLatency}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"    format error: {ex.GetType().Name} 0x{ex.HResult:X8} {ex.Message}");
    }
}

Console.WriteLine("\n=== WasapiOut variants (default device) ===");
foreach (var useEvent in new[] { true, false })
{
    foreach (var latency in new[] { 20, 50, 100 })
    {
        TryVariant(null, useEvent, latency);
    }
}

Console.WriteLine("\n=== WasapiOut variants (each active device, 48k float stereo buffered) ===");
foreach (var info in service.GetRenderDevices())
{
    Console.WriteLine($"-- {info.Name}");
    TryVariant(info.Id, true, 50);
    TryVariant(info.Id, false, 50);
}

Console.WriteLine("\n=== LoopbackCaptureService (process loopback attempt) ===");
var loopback = new LoopbackCaptureService();
loopback.Start("process");
Console.WriteLine($"mode={loopback.Mode} capturing={loopback.IsCapturing} excludesOwn={loopback.ExcludesOwnAudio} error={loopback.Error}");
Thread.Sleep(600);
loopback.Stop();

Console.WriteLine("\n=== MicOutputEngine ===");
try
{
    var mix = new AirMicHub.Core.Audio.MixEngine();
    using var engine = new MicOutputEngine(mix, service);
    engine.Start(null);
    Console.WriteLine($"started={engine.IsRunning} error={engine.Error} latency={engine.LatencyMilliseconds}");
    engine.PlayTestTone();
    Thread.Sleep(500);
}
catch (Exception ex)
{
    Console.WriteLine($"engine exception: {ex}");
}

static void TryVariant(string? deviceId, bool useEvent, int latency)
{
    var service = new AudioDeviceService();
    MMDevice? device = null;
    WasapiOut? output = null;
    try
    {
        device = service.OpenDevice(deviceId, DataFlow.Render);
        if (device is null) { Console.WriteLine($"  event={useEvent} latency={latency}: no device"); return; }
        var format = device.AudioClient.MixFormat;
        var buffered = new BufferedWaveProvider(format) { BufferDuration = TimeSpan.FromSeconds(1), ReadFully = false };
        var silence = new byte[format.AverageBytesPerSecond / 10];
        buffered.AddSamples(silence, 0, silence.Length);
        output = new WasapiOut(device, AudioClientShareMode.Shared, useEvent, latency);
        output.Init(buffered);
        output.Play();
        Thread.Sleep(250);
        Console.WriteLine($"  event={useEvent} latency={latency}: OK ({format.SampleRate} Hz/{format.Channels}ch/{format.BitsPerSample}bit {format.Encoding}) state={output.PlaybackState}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"  event={useEvent} latency={latency}: FAIL 0x{ex.HResult:X8} {ex.GetType().Name}: {ex.Message}");
    }
    finally
    {
        try { output?.Stop(); } catch { }
        try { output?.Dispose(); } catch { }
        try { device?.Dispose(); } catch { }
    }
}
