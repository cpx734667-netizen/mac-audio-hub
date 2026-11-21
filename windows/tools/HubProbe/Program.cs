using System.Net.Http;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

// Protocol smoke probe for a running AirMic Hub instance.
// Usage: HubProbe --mic https://127.0.0.1:8766 --speaker http://127.0.0.1:8788 [--play-tone]

var micBase = "https://127.0.0.1:8766";
var speakerBase = "http://127.0.0.1:8788";
var skipSpeakerStart = false;
var playTone = false;
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--mic": micBase = args[++i]; break;
        case "--speaker": speakerBase = args[++i]; break;
        case "--skip-speaker-start": skipSpeakerStart = true; break;
        case "--play-tone": playTone = true; break;
    }
}

var result = new Dictionary<string, object?>();
using var http = new HttpClient(new HttpClientHandler
{
    ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator,
})
{
    Timeout = TimeSpan.FromSeconds(10),
};

try
{
    var micPage = await http.GetStringAsync(micBase + "/");
    var micHealth = await http.GetStringAsync(micBase + "/health");
    result["micPageHasComputerCopy"] = micPage.Contains("电脑在线", StringComparison.Ordinal) &&
                                      !micPage.Contains("Mac 在线", StringComparison.Ordinal);
    result["micPageHasWorklet"] = micPage.Contains("pcm-worklet.js", StringComparison.Ordinal);
    result["micHealth"] = JsonSerializer.Deserialize<JsonElement>(micHealth);
}
catch (Exception ex)
{
    result["micHttpError"] = ex.Message;
}

try
{
    var speakerPage = await http.GetStringAsync(speakerBase + "/");
    var speakerHealth = await http.GetStringAsync(speakerBase + "/health");
    result["speakerPageHasComputerCopy"] = speakerPage.Contains("电脑音箱", StringComparison.Ordinal);
    result["speakerPageHas300msBuffer"] = speakerPage.Contains("TARGET_LATENCY_MS = 300", StringComparison.Ordinal);
    result["speakerHealth"] = JsonSerializer.Deserialize<JsonElement>(speakerHealth);
}
catch (Exception ex)
{
    result["speakerHttpError"] = ex.Message;
}

try
{
    using var mic = new ClientWebSocket();
    mic.Options.RemoteCertificateValidationCallback = (_, _, _, _) => true;
    await mic.ConnectAsync(new Uri(micBase.Replace("https://", "wss://") + "/ws"), CancellationToken.None);
    await SendTextAsync(mic, "{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"HubProbe\",\"platform\":\"Windows\"}");
    var ready = await WaitForTypeAsync(mic, "ready", TimeSpan.FromSeconds(6));
    result["micReady"] = ready;

    var pcm = new byte[480];
    for (var i = 0; i < 240; i++)
    {
        var value = (short)(12000 * Math.Sin(2 * Math.PI * 440 * i / 48000.0));
        pcm[i * 2] = (byte)(value & 0xFF);
        pcm[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
    }
    await mic.SendAsync(pcm, WebSocketMessageType.Binary, true, CancellationToken.None);
    result["micStats"] = await WaitForTypeAsync(mic, "stats", TimeSpan.FromSeconds(8));
    result["micHealthAfter"] = JsonSerializer.Deserialize<JsonElement>(
        await http.GetStringAsync(micBase + "/health"));
    await mic.CloseAsync(WebSocketCloseStatus.NormalClosure, "probe done", CancellationToken.None);
}
catch (Exception ex)
{
    result["micWebSocketError"] = ex.Message;
}

if (!skipSpeakerStart)
{
    try
    {
        using var speaker = new ClientWebSocket();
        await speaker.ConnectAsync(new Uri(speakerBase.Replace("http://", "ws://") + "/ws"), CancellationToken.None);
        var ready = await WaitForTypeAsync(speaker, "ready", TimeSpan.FromSeconds(6));
        result["speakerReady"] = ready;
        await SendTextAsync(speaker, "{\"type\":\"device\",\"id\":\"hubprobe-device\",\"name\":\"HubProbe\"}");
        await SendTextAsync(speaker, "{\"type\":\"start\"}");

        var state = await WaitForAnyTypeAsync(speaker, new[] { "state", "error" }, TimeSpan.FromSeconds(20));
        result["speakerStartResult"] = state;

        // Read health while the capture is actually running (mode/exclusion evidence).
        await Task.Delay(700);
        result["speakerHealthDuring"] = JsonSerializer.Deserialize<JsonElement>(
            await http.GetStringAsync(speakerBase + "/health"));

        if (playTone && state.TryGetProperty("type", out var stateType) && stateType.GetString() == "state")
        {
            var format = ready.TryGetProperty("format", out var formatProperty)
                ? formatProperty.GetString() ?? "float32le"
                : "float32le";
            var wavPath = WriteToneWav();
            result["toneFile"] = wavPath;
            Native.PlaySound(wavPath, IntPtr.Zero, Native.SndFilename | Native.SndAsync | Native.SndNoDefault);
            try
            {
                long bytes = 0;
                var binaryFrames = 0;
                double sumSquares = 0;
                long samples = 0;
                var deadline = DateTime.UtcNow.AddSeconds(3);
                while (DateTime.UtcNow < deadline)
                {
                    (WebSocketMessageType Type, byte[] Payload) message;
                    try
                    {
                        message = await ReceiveAsync(speaker, TimeSpan.FromSeconds(1));
                    }
                    catch (OperationCanceledException)
                    {
                        // No frame within a second: keep waiting until the overall deadline so
                        // the probe can still report how many frames did arrive.
                        continue;
                    }
                    if (message.Type == WebSocketMessageType.Close) break;
                    if (message.Type != WebSocketMessageType.Binary) continue;
                    binaryFrames++;
                    bytes += message.Payload.Length;
                    if (format == "int16le")
                    {
                        for (var offset = 0; offset + 1 < message.Payload.Length; offset += 2)
                        {
                            var sample = BitConverter.ToInt16(message.Payload, offset) / 32768.0;
                            sumSquares += sample * sample;
                            samples++;
                        }
                    }
                    else
                    {
                        for (var offset = 0; offset + 3 < message.Payload.Length; offset += 4)
                        {
                            var sample = BitConverter.ToSingle(message.Payload, offset);
                            sumSquares += sample * sample;
                            samples++;
                        }
                    }
                }

                result["binaryFrames"] = binaryFrames;
                result["binaryBytes"] = bytes;
                result["binaryRms"] = Math.Round(samples == 0 ? 0 : Math.Sqrt(sumSquares / samples), 5);
                result["binaryFormat"] = format;
                await SendTextAsync(speaker, "{\"type\":\"stop\"}");
            }
            finally
            {
                Native.PlaySound(null, IntPtr.Zero, 0);
                try { File.Delete(wavPath); } catch { }
            }
        }

        // Give the capture pipeline a moment, then read the health endpoint again.
        await Task.Delay(800);
        result["speakerHealthAfter"] = JsonSerializer.Deserialize<JsonElement>(
            await http.GetStringAsync(speakerBase + "/health"));
    }
    catch (Exception ex)
    {
        result["speakerWebSocketError"] = ex.Message;
    }
}

Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions
{
    WriteIndented = true,
    Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
}));

static Task SendTextAsync(ClientWebSocket socket, string text) =>
    socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, CancellationToken.None);

static async Task<JsonElement> WaitForTypeAsync(ClientWebSocket socket, string type, TimeSpan timeout)
{
    var deadline = DateTime.UtcNow + timeout;
    while (DateTime.UtcNow < deadline)
    {
        var message = await ReceiveAsync(socket, deadline - DateTime.UtcNow);
        if (message.Type != WebSocketMessageType.Text) continue;
        var document = JsonDocument.Parse(message.Payload);
        if (document.RootElement.TryGetProperty("type", out var value) && value.GetString() == type)
        {
            return document.RootElement.Clone();
        }
    }
    throw new TimeoutException("没有等到 " + type);
}

static async Task<JsonElement> WaitForAnyTypeAsync(ClientWebSocket socket, string[] types, TimeSpan timeout)
{
    var deadline = DateTime.UtcNow + timeout;
    while (DateTime.UtcNow < deadline)
    {
        var message = await ReceiveAsync(socket, deadline - DateTime.UtcNow);
        if (message.Type != WebSocketMessageType.Text) continue;
        var document = JsonDocument.Parse(message.Payload);
        if (document.RootElement.TryGetProperty("type", out var value) &&
            types.Contains(value.GetString()))
        {
            return document.RootElement.Clone();
        }
    }
    throw new TimeoutException("没有等到 " + string.Join("/", types));
}

static async Task<(WebSocketMessageType Type, byte[] Payload)> ReceiveAsync(ClientWebSocket socket, TimeSpan timeout)
{
    using var cts = new CancellationTokenSource(timeout);
    var buffer = new byte[128 * 1024];
    using var memory = new MemoryStream();
    WebSocketMessageType messageType = WebSocketMessageType.Text;
    while (true)
    {
        var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), cts.Token);
        if (result.MessageType == WebSocketMessageType.Close) return (WebSocketMessageType.Close, Array.Empty<byte>());
        messageType = result.MessageType;
        memory.Write(buffer, 0, result.Count);
        if (result.EndOfMessage) break;
    }
    return (messageType, memory.ToArray());
}

static string WriteToneWav()
{
    const int rate = 48000;
    const int channels = 2;
    const int seconds = 2;
    var frames = rate * seconds;
    var data = new byte[frames * channels * 2];
    for (var i = 0; i < frames; i++)
    {
        var t = i / (double)frames;
        var fade = Math.Min(1.0, Math.Min(t / 0.05, (1 - t) / 0.08));
        var value = (short)(Math.Sin(2 * Math.PI * 440 * i / rate) * 0.22 * fade * 32767);
        data[i * 4] = (byte)(value & 0xFF);
        data[i * 4 + 1] = (byte)((value >> 8) & 0xFF);
        data[i * 4 + 2] = data[i * 4];
        data[i * 4 + 3] = data[i * 4 + 1];
    }

    using var stream = new MemoryStream();
    using var writer = new BinaryWriter(stream);
    writer.Write(Encoding.ASCII.GetBytes("RIFF"));
    writer.Write(36 + data.Length);
    writer.Write(Encoding.ASCII.GetBytes("WAVE"));
    writer.Write(Encoding.ASCII.GetBytes("fmt "));
    writer.Write(16);
    writer.Write((short)1);
    writer.Write((short)channels);
    writer.Write(rate);
    writer.Write(rate * channels * 2);
    writer.Write((short)(channels * 2));
    writer.Write((short)16);
    writer.Write(Encoding.ASCII.GetBytes("data"));
    writer.Write(data.Length);
    writer.Write(data);
    var path = Path.Combine(Path.GetTempPath(), "airmic-hubprobe-tone.wav");
    File.WriteAllBytes(path, stream.ToArray());
    return path;
}

internal static class Native
{
    public const uint SndAsync = 0x0001;
    public const uint SndNoDefault = 0x0002;
    public const uint SndFilename = 0x00020000;

    [DllImport("winmm.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool PlaySound(string? sound, IntPtr module, uint flags);
}
