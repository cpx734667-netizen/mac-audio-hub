using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using AirMicHub.Audio;
using AirMicHub.Core;
using AirMicHub.Core.Audio;
using AirMicHub.Core.Certificates;
using AirMicHub.Core.State;
using AirMicHub.Server;

[assembly: Xunit.CollectionBehavior(DisableTestParallelization = true)]

namespace AirMicHub.Tests;

/// <summary>Spins up a real Kestrel host on free loopback ports with a throwaway certificate.</summary>
public sealed class TestHub : IAsyncDisposable
{
    private readonly string _directory;

    private TestHub(string directory, HubServer server, MixEngine mix, HubState state, int micPort, int speakerPort)
    {
        _directory = directory;
        Server = server;
        Mix = mix;
        State = state;
        MicPort = micPort;
        SpeakerPort = speakerPort;
    }

    public HubServer Server { get; }
    public MixEngine Mix { get; }
    public HubState State { get; }
    public int MicPort { get; }
    public int SpeakerPort { get; }

    public string MicBaseUrl => $"https://127.0.0.1:{MicPort}";
    public string SpeakerBaseUrl => $"http://127.0.0.1:{SpeakerPort}";

    public static async Task<TestHub> StartAsync(Action<ServerConfigBuilder>? configure = null)
    {
        var directory = Path.Combine(Path.GetTempPath(), "airmic-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var mix = new MixEngine();
        var state = new HubState();
        var certificates = new CertificateManager(Path.Combine(directory, "cert.pfx"));
        var loopback = new LoopbackCaptureService();
        var builder = new ServerConfigBuilder();
        configure?.Invoke(builder);

        var micPort = FreePort();
        var speakerPort = FreePort();
        var config = new ServerConfig
        {
            MicPort = micPort,
            SpeakerPort = speakerPort,
            EfficientMode = builder.EfficientMode,
            CaptureMode = builder.CaptureMode,
            CaptureEnabled = builder.CaptureEnabled,
        };

        var server = new HubServer(mix, state, loopback, certificates, config);
        await server.StartAsync();
        return new TestHub(directory, server, mix, state, micPort, speakerPort);
    }

    public static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    public async ValueTask DisposeAsync()
    {
        await Server.DisposeAsync();
        try { Directory.Delete(_directory, recursive: true); } catch { }
    }
}

public sealed class ServerConfigBuilder
{
    public bool EfficientMode { get; set; }
    public bool CaptureEnabled { get; set; } = true;
    public string CaptureMode { get; set; } = "auto";
}

public static class TestHttp
{
    public static HttpClient CreateInsecureClient()
    {
        var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator,
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    }

    public static async Task<JsonDocument> GetJsonAsync(HttpClient client, string url)
    {
        var text = await client.GetStringAsync(url);
        return JsonDocument.Parse(text);
    }

    public static async Task<ClientWebSocket> ConnectAsync(string url, TimeSpan? timeout = null)
    {
        var socket = new ClientWebSocket();
        socket.Options.RemoteCertificateValidationCallback = (_, _, _, _) => true;
        using var cts = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(10));
        await socket.ConnectAsync(new Uri(url), cts.Token);
        return socket;
    }

    public static Task SendTextAsync(ClientWebSocket socket, string json) =>
        socket.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Text, true, CancellationToken.None);

    public static Task SendBinaryAsync(ClientWebSocket socket, byte[] payload) =>
        socket.SendAsync(payload, WebSocketMessageType.Binary, true, CancellationToken.None);

    public static async Task<(WebSocketMessageType Type, byte[] Payload)> ReceiveAsync(
        ClientWebSocket socket,
        TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        var buffer = new byte[128 * 1024];
        using var memory = new MemoryStream();
        WebSocketMessageType messageType = WebSocketMessageType.Text;
        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), cts.Token);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return (WebSocketMessageType.Close, Array.Empty<byte>());
            }
            messageType = result.MessageType;
            memory.Write(buffer, 0, result.Count);
            if (result.EndOfMessage) break;
        }
        return (messageType, memory.ToArray());
    }

    public static async Task<JsonDocument> WaitForTypeAsync(ClientWebSocket socket, string type, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var remaining = deadline - DateTime.UtcNow;
            var message = await ReceiveAsync(socket, remaining);
            if (message.Type == WebSocketMessageType.Close)
            {
                throw new InvalidOperationException("WebSocket closed while waiting for " + type);
            }
            if (message.Type != WebSocketMessageType.Text) continue;
            var document = JsonDocument.Parse(message.Payload);
            if (document.RootElement.TryGetProperty("type", out var value) && value.GetString() == type)
            {
                return document;
            }
            document.Dispose();
        }
        throw new TimeoutException("没有等到 " + type);
    }
}
