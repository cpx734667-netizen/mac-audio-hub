using System.Net;
using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using AirMicHub.Audio;
using AirMicHub.Core;
using AirMicHub.Core.Audio;
using AirMicHub.Core.Certificates;
using AirMicHub.Core.Protocol;
using AirMicHub.Core.State;

namespace AirMicHub.Server;

public sealed class ServerConfig
{
    public int MicPort { get; init; } = 8765;
    public int SpeakerPort { get; init; } = 8787;
    public bool EfficientMode { get; init; }
    public string CaptureMode { get; init; } = "auto";
    public bool CaptureEnabled { get; init; } = true;
}

public sealed class HubServerException : Exception
{
    public HubServerException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>
/// One Kestrel host with two listeners: HTTPS/WSS 8765 for the phone microphone page and
/// HTTP/WS 8787 for the phone speaker page. Requests are dispatched by local port so the two
/// protocols stay isolated while sharing a single process and lifetime.
/// </summary>
public sealed class HubServer : IAsyncDisposable
{
    private readonly MixEngine _mix;
    private readonly HubState _state;
    private readonly LoopbackCaptureService _loopback;
    private readonly CertificateManager _certificates;
    private readonly ServerConfig _config;

    private WebApplication? _app;
    private X509Certificate2? _certificate;

    public HubServer(
        MixEngine mix,
        HubState state,
        LoopbackCaptureService loopback,
        CertificateManager certificates,
        ServerConfig config)
    {
        _mix = mix;
        _state = state;
        _loopback = loopback;
        _certificates = certificates;
        _config = config;
        Mic = new MicHub(mix, state);
        Speaker = new SpeakerHub(loopback, state, config.CaptureMode);
    }

    public MicHub Mic { get; }
    public SpeakerHub Speaker { get; }
    public bool IsRunning { get; private set; }
    public int MicPort => _config.MicPort;
    public int SpeakerPort => _config.SpeakerPort;

    public async Task StartAsync(CancellationToken token = default)
    {
        if (_app is not null) return;

        try
        {
            var lanAddresses = NetworkInfo.GetLanIpv4Addresses();
            _certificate = _certificates.GetOrCreate(lanAddresses, Environment.MachineName);

            var builder = WebApplication.CreateBuilder(new WebApplicationOptions
            {
                ApplicationName = typeof(HubServer).Assembly.GetName().Name,
                ContentRootPath = AppContext.BaseDirectory,
                Args = Array.Empty<string>(),
            });
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(options =>
            {
                options.AddServerHeader = false;
                options.Limits.MaxRequestBodySize = 16 * 1024;
                options.Limits.MinRequestBodyDataRate = null;
                options.Limits.MinResponseDataRate = null;
                // Bind IPv4 explicitly: phones use the IPv4 address from the QR code and an
                // IPv6-only listener can silently coexist with another process on IPv4:8765.
                options.Listen(System.Net.IPAddress.Any, _config.MicPort, listen => listen.UseHttps(_certificate));
                options.Listen(System.Net.IPAddress.Any, _config.SpeakerPort);            });

            var app = builder.Build();
            app.UseWebSockets(new WebSocketOptions
            {
                KeepAliveInterval = TimeSpan.FromSeconds(20),
            });
            app.Run(HandleRequestAsync);

            await app.StartAsync(token);
            _app = app;

            Mic.Start(_config.MicPort);
            Speaker.Start(_config.SpeakerPort, _config.EfficientMode);
            Speaker.SetCaptureEnabled(_config.CaptureEnabled);
            IsRunning = true;
            Log.Info($"服务已启动：麦克风 https://0.0.0.0:{_config.MicPort}/ ，音箱 http://0.0.0.0:{_config.SpeakerPort}/");
            _state.UpdateMic(builderState =>
            {
                builderState.Listening = true;
                builderState.Port = _config.MicPort;
                builderState.Error = null;
            });
            _state.UpdateSpeaker(builderState =>
            {
                builderState.Listening = true;
                builderState.Port = _config.SpeakerPort;
                builderState.Error = null;
                builderState.Efficient = _config.EfficientMode;
                builderState.Format = _config.EfficientMode ? Protocol.Int16Le : Protocol.Float32Le;
                builderState.CaptureEnabled = _config.CaptureEnabled;
            });
        }
        catch (Exception ex)
        {
            var friendly = FriendlyStartupError(ex);
            _state.UpdateMic(builderState => builderState.Error = friendly.MicError);
            _state.UpdateSpeaker(builderState => builderState.Error = friendly.SpeakerError);
            Log.Error("服务启动失败", ex);
            await DisposeHostAsync();
            throw new HubServerException(friendly.Message, ex);
        }
    }

    private (string Message, string? MicError, string? SpeakerError) FriendlyStartupError(Exception ex)
    {
        var conflict = ex is AddressInUseException ||
                       ex.InnerException is AddressInUseException ||
                       ex.Message.Contains("address already in use", StringComparison.OrdinalIgnoreCase) ||
                       ex.Message.Contains("bind", StringComparison.OrdinalIgnoreCase) && ex is IOException;

        if (conflict)
        {
            var message = $"端口被占用：请关闭占用 {_config.MicPort}（麦克风）或 {_config.SpeakerPort}（音箱）的程序，" +
                          "或在设置中改用其他端口。";
            return (message,
                $"端口 {_config.MicPort} 被占用，手机麦克风无法启动。",
                $"端口 {_config.SpeakerPort} 被占用，手机音箱无法启动。");
        }

        if (ex is System.Security.Cryptography.CryptographicException)
        {
            const string message = "本地证书生成/加载失败。请删除 %LOCALAPPDATA%\\AirMicHub\\cert.pfx 后重启 App。";
            return (message, message, message);
        }

        return ($"服务启动失败：{ex.Message}", $"麦克风服务启动失败：{ex.Message}", $"音箱服务启动失败：{ex.Message}");
    }

    private async Task HandleRequestAsync(HttpContext context)
    {
        try
        {
            var localPort = context.Connection.LocalPort;
            var path = context.Request.Path.Value ?? "/";

            if (localPort == _config.MicPort)
            {
                await HandleMicRequestAsync(context, path);
            }
            else if (localPort == _config.SpeakerPort)
            {
                await HandleSpeakerRequestAsync(context, path);
            }
            else
            {
                await HttpUtil.WriteTextAsync(context, StatusCodes.Status404NotFound, "Not found");
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or Microsoft.AspNetCore.Connections.ConnectionResetException or IOException)
        {
            // Browser closed the socket mid-response; nothing useful to send.
        }
        catch (Exception ex)
        {
            Log.Warn($"HTTP 请求处理失败（{context.Request.Path}）：{ex.Message}");
            if (!context.Response.HasStarted)
            {
                context.Response.StatusCode = StatusCodes.Status500InternalServerError;
            }
        }
    }

    private async Task HandleMicRequestAsync(HttpContext context, string path)
    {
        if (!HttpMethods.IsGet(context.Request.Method) && !HttpMethods.IsHead(context.Request.Method))
        {
            await HttpUtil.WriteTextAsync(context, StatusCodes.Status405MethodNotAllowed, "Method not allowed");
            return;
        }

        if (path == "/ws")
        {
            if (!context.WebSockets.IsWebSocketRequest)
            {
                await HttpUtil.WriteTextAsync(context, StatusCodes.Status400BadRequest, "Expected WebSocket upgrade");
                return;
            }
            await Mic.AcceptAsync(context);
            return;
        }

        switch (path)
        {
            case "/":
            case "/index.html":
                await HttpUtil.WriteBytesAsync(context, AssetStore.PhoneHtml, "text/html; charset=utf-8",
                    extraHeaders: new Dictionary<string, string> { ["Permissions-Policy"] = "microphone=(self)" });
                break;
            case "/pcm-worklet.js":
                await HttpUtil.WriteBytesAsync(context, AssetStore.Worklet, "application/javascript; charset=utf-8");
                break;
            case "/manifest.webmanifest":
                await HttpUtil.WriteBytesAsync(context, AssetStore.Manifest, "application/manifest+json; charset=utf-8");
                break;
            case "/favicon.svg":
                await HttpUtil.WriteBytesAsync(context, AssetStore.Favicon, "image/svg+xml");
                break;
            case "/favicon.ico":
                context.Response.StatusCode = StatusCodes.Status204NoContent;
                break;
            case "/health":
                await HttpUtil.WriteJsonAsync(context, Mic.BuildHealth());
                break;
            default:
                await HttpUtil.WriteTextAsync(context, StatusCodes.Status404NotFound, "Not found");
                break;
        }
    }

    private async Task HandleSpeakerRequestAsync(HttpContext context, string path)
    {
        if (!HttpMethods.IsGet(context.Request.Method) && !HttpMethods.IsHead(context.Request.Method))
        {
            await HttpUtil.WriteTextAsync(context, StatusCodes.Status405MethodNotAllowed, "Method not allowed");
            return;
        }

        if (path == "/ws")
        {
            if (!context.WebSockets.IsWebSocketRequest)
            {
                await HttpUtil.WriteTextAsync(context, StatusCodes.Status400BadRequest, "Expected WebSocket upgrade");
                return;
            }
            await Speaker.AcceptAsync(context);
            return;
        }

        switch (path)
        {
            case "/":
            case "/index.html":
                await HttpUtil.WriteBytesAsync(context, AssetStore.SpeakerHtml, "text/html; charset=utf-8");
                break;
            case "/favicon.svg":
                await HttpUtil.WriteBytesAsync(context, AssetStore.Favicon, "image/svg+xml");
                break;
            case "/favicon.ico":
                context.Response.StatusCode = StatusCodes.Status204NoContent;
                break;
            case "/health":
                await HttpUtil.WriteJsonAsync(context, Speaker.BuildHealth());
                break;
            default:
                await HttpUtil.WriteTextAsync(context, StatusCodes.Status404NotFound, "Not found");
                break;
        }
    }

    public async Task StopAsync()
    {
        IsRunning = false;
        try { await Mic.StopAsync(); } catch (Exception ex) { Log.Warn($"停止麦克风服务失败：{ex.Message}"); }
        try { await Speaker.StopAsync(); } catch (Exception ex) { Log.Warn($"停止音箱服务失败：{ex.Message}"); }
        await DisposeHostAsync();
        _state.UpdateMic(builderState => builderState.Listening = false);
        _state.UpdateSpeaker(builderState => builderState.Listening = false);
        Log.Info("服务已停止。");
    }

    private async Task DisposeHostAsync()
    {
        var app = _app;
        _app = null;
        if (app is null) return;
        try
        {
            await app.StopAsync(TimeSpan.FromSeconds(3));
        }
        catch (Exception ex)
        {
            Log.Warn($"停止 Kestrel 失败：{ex.Message}");
        }
        try
        {
            await app.DisposeAsync();
        }
        catch (Exception ex)
        {
            Log.Warn($"释放 Kestrel 失败：{ex.Message}");
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        // The certificate is owned and cached by CertificateManager so a failed bind can be
        // retried with the same instance. Never dispose it here.
        _certificate = null;
    }
}
