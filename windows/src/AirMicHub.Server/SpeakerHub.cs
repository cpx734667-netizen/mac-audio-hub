using System.Net.WebSockets;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.AspNetCore.Http;
using AirMicHub.Audio;
using AirMicHub.Core;
using AirMicHub.Core.Audio;
using AirMicHub.Core.Protocol;
using AirMicHub.Core.State;

namespace AirMicHub.Server;

/// <summary>
/// 8787 speaker hub: broadcasts WASAPI loopback audio to phones that open the player page.
/// Keeps the reference protocol (ready/device/start/stop/state, Float32 or Int16 binary) and
/// the 300 ms browser-side buffer. Capture starts only while at least one phone is listening.
/// </summary>
public sealed class SpeakerHub : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, SpeakerClient> _clients = new();
    private readonly LoopbackCaptureService _loopback;
    private readonly HubState _state;
    private readonly string _requestedCaptureMode;
    private readonly Channel<byte[]> _frames = Channel.CreateBounded<byte[]>(
        new BoundedChannelOptions(8) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });

    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private Task? _heartbeatTask;
    private Task? _statsTask;
    private bool _listening;
    private bool _efficient;
    private bool _captureEnabled = true;
    private bool _captureStarting;
    private int _port = 8787;
    private long _bytesSinceStats;
    private double _bytesPerSecond;
    private string? _feedbackWarning;

    public SpeakerHub(LoopbackCaptureService loopback, HubState state, string requestedCaptureMode = "auto")
    {
        _loopback = loopback;
        _state = state;
        _requestedCaptureMode = requestedCaptureMode;
    }

    public int Port => _port;
    public bool Listening => _listening;
    public bool Efficient => _efficient;
    public bool CaptureEnabled => _captureEnabled;
    public int ActiveCount
    {
        get
        {
            lock (_gate) return _clients.Values.Count(client => client.Active);
        }
    }

    internal CancellationToken Token => _cts?.Token ?? CancellationToken.None;

    public void Start(int port, bool efficient)
    {
        _port = port;
        _efficient = efficient;
        _listening = true;
        _cts = new CancellationTokenSource();
        _loopback.AudioAvailable += OnLoopbackAudio;
        _loopback.StateChanged += OnLoopbackStateChanged;
        _loopback.ErrorChanged += OnLoopbackError;
        _pumpTask = Task.Run(() => PumpAsync(_cts.Token));
        _heartbeatTask = Task.Run(() => HeartbeatAsync(_cts.Token));
        _statsTask = Task.Run(() => StatsLoopAsync(_cts.Token));
        _state.UpdateSpeaker(builder =>
        {
            builder.Listening = true;
            builder.Port = port;
            builder.Error = null;
            builder.Efficient = efficient;
            builder.Format = efficient ? Protocol.Int16Le : Protocol.Float32Le;
            builder.CaptureEnabled = _captureEnabled;
            builder.Capturing = false;
            builder.CaptureMode = "idle";
        });
        Log.Info($"音箱服务已启动：http://0.0.0.0:{port}/");
    }

    public async Task StopAsync()
    {
        _listening = false;
        try { _cts?.Cancel(); } catch { }

        _loopback.AudioAvailable -= OnLoopbackAudio;
        _loopback.StateChanged -= OnLoopbackStateChanged;
        _loopback.ErrorChanged -= OnLoopbackError;
        _loopback.Stop();

        List<SpeakerClient> clients;
        lock (_gate)
        {
            clients = _clients.Values.ToList();
            _clients.Clear();
        }
        foreach (var client in clients)
        {
            await client.CloseAsync("服务停止");
        }

        foreach (var task in new[] { _pumpTask, _heartbeatTask, _statsTask })
        {
            if (task is null) continue;
            try { await task; } catch (OperationCanceledException) { } catch (Exception ex) { Log.Warn($"音箱循环退出异常：{ex.Message}"); }
        }

        _frames.Writer.TryComplete();
        _state.UpdateSpeaker(builder =>
        {
            builder.Listening = false;
            builder.Capturing = false;
            builder.CaptureEnabled = _captureEnabled;
            builder.CaptureMode = "idle";
            builder.Devices = Array.Empty<SpeakerDeviceStatus>();
            builder.ActiveCount = 0;
            builder.BytesPerSecond = 0;
        });
        Log.Info("8787 音箱服务已停止。");
    }

    public async ValueTask DisposeAsync() => await StopAsync();

    public async Task AcceptAsync(HttpContext context)
    {
        var socket = await context.WebSockets.AcceptWebSocketAsync();
        var client = new SpeakerClient(
            this,
            Guid.NewGuid(),
            socket,
            context.Connection.RemoteIpAddress?.ToString() ?? "未知");
        lock (_gate)
        {
            _clients[client.Id] = client;
        }
        client.Start();
        RefreshStatus();
        Log.Info($"音箱设备已连接：{client.Address}");

        try
        {
            await SendReadyAsync(client);
        }
        catch (Exception ex)
        {
            Log.Warn($"向音箱设备 {client.Address} 发送 ready 失败：{ex.Message}");
            await RemoveClientAsync(client, "连接关闭");
            return;
        }

        try
        {
            await client.ReceiveLoopAsync();
        }
        catch (WebSocketException ex)
        {
            Log.Info($"音箱设备 {client.Address} 连接中断：{ex.Message}");
        }
        catch (OperationCanceledException)
        {
            // shutting down
        }
        catch (Exception ex)
        {
            Log.Warn($"音箱设备 {client.Address} 异常：{ex.Message}");
        }
        finally
        {
            await RemoveClientAsync(client, "连接关闭");
        }
    }

    public void SetEfficient(bool efficient)
    {
        _efficient = efficient;
        BroadcastState(null, efficient ? Protocol.Int16Le : Protocol.Float32Le);
        RefreshStatus();
        Log.Info($"8787 传输模式：{(efficient ? "Int16LE 高效" : "Float32LE 高质量")}");
    }

    public void SetCaptureEnabled(bool enabled)
    {
        _captureEnabled = enabled;
        if (!enabled)
        {
            _loopback.Stop();
            BroadcastState(playing: false, format: null);
            BroadcastError("电脑端已关闭系统音频捕获。");
        }
        else if (ActiveCount > 0)
        {
            StartCaptureIfNeeded();
        }
        RefreshStatus();
    }

    public void SetFeedbackWarning(string? message)
    {
        _feedbackWarning = message;
        RefreshStatus();
    }

    public string? CaptureError => _loopback.Error;
    public bool ExcludesOwnAudio => _loopback.ExcludesOwnAudio;
    public string CaptureMode => _loopback.IsCapturing ? _loopback.Mode : "idle";

    private async Task SendReadyAsync(SpeakerClient client)
    {
        var message = new SpeakerReadyMessage
        {
            Format = _efficient ? Protocol.Int16Le : Protocol.Float32Le,
            DeviceId = client.Id.ToString(),
        };
        await client.SendControlAsync(JsonSerializer.SerializeToUtf8Bytes(message, Protocol.JsonOptions));
    }

    private void StartCaptureIfNeeded()
    {
        if (!_captureEnabled || _loopback.IsCapturing || _captureStarting) return;
        _captureStarting = true;
        _ = Task.Run(() =>
        {
            try
            {
                _loopback.Start(_requestedCaptureMode);
                if (!_captureEnabled)
                {
                    // The user disabled capture while process-loopback activation was in
                    // flight; do not leave the microphone/system audio tap running.
                    _loopback.Stop();
                    RefreshStatus();
                    return;
                }
                if (!_listening)
                {
                    _loopback.Stop();
                    return;
                }
                if (!_loopback.IsCapturing)
                {
                    BroadcastError(_loopback.Error ?? "系统音频捕获启动失败。");
                }
                else
                {
                    Log.Info($"8787 捕获已启动（模式：{_loopback.Mode}）。");
                }
            }
            catch (Exception ex)
            {
                BroadcastError($"系统音频捕获失败：{ex.Message}");
                Log.Error("8787 捕获启动失败", ex);
            }
            finally
            {
                _captureStarting = false;
                RefreshStatus();
            }
        });
    }

    private void OnLoopbackAudio(float[] samples)
    {
        if (samples.Length == 0) return;
        if (ActiveCount == 0) return;

        try
        {
            var frame = _efficient ? Pcm.FloatToInt16(samples) : Pcm.FloatToBytes(samples);
            Interlocked.Add(ref _bytesSinceStats, frame.Length);
            _frames.Writer.TryWrite(frame);
        }
        catch (Exception ex)
        {
            Log.Warn($"编码系统音频帧失败：{ex.Message}");
        }
    }

    private async Task PumpAsync(CancellationToken token)
    {
        try
        {
            await foreach (var frame in _frames.Reader.ReadAllAsync(token))
            {
                List<SpeakerClient> active;
                lock (_gate) active = _clients.Values.Where(client => client.Active).ToList();
                foreach (var client in active)
                {
                    client.TryQueueAudio(frame);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    private async Task HeartbeatAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
        try
        {
            while (await timer.WaitForNextTickAsync(token))
            {
                List<SpeakerClient> clients;
                lock (_gate) clients = _clients.Values.ToList();

                foreach (var client in clients)
                {
                    if (DateTime.UtcNow - client.LastActivity > TimeSpan.FromSeconds(45))
                    {
                        Log.Warn($"音箱设备 {client.Address} 心跳超时，已移除。");
                        _ = RemoveClientAsync(client, "心跳超时");
                        continue;
                    }

                    var ping = JsonSerializer.SerializeToUtf8Bytes(new PingMessage
                    {
                        T = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    }, Protocol.JsonOptions);
                    try
                    {
                        await client.SendControlAsync(ping);
                    }
                    catch (Exception ex)
                    {
                        Log.Warn($"向音箱设备 {client.Address} 发送心跳失败，已移除：{ex.Message}");
                        _ = RemoveClientAsync(client, "心跳发送失败");
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    private async Task StatsLoopAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try
        {
            while (await timer.WaitForNextTickAsync(token))
            {
                var bytes = Interlocked.Exchange(ref _bytesSinceStats, 0);
                _bytesPerSecond = _bytesPerSecond * 0.5 + bytes * 0.5;
                RefreshStatus();
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    private void OnLoopbackStateChanged() => RefreshStatus();

    private void OnLoopbackError(string message)
    {
        BroadcastError(message);
        RefreshStatus();
    }

    internal async Task HandleMessageAsync(SpeakerClient client, byte[] payload)
    {
        client.Touch();
        lock (_gate)
        {
            // A client that was just superseded may still deliver one queued message; it must
            // not be allowed to kick the connection that replaced it.
            if (!_clients.ContainsKey(client.Id)) return;
        }
        var type = ProtocolJson.ReadType(payload);
        if (type is null) return;

        switch (type)
        {
            case "device":
            {
                var deviceId = ProtocolJson.ReadString(payload, "id");
                var name = ProtocolJson.ReadString(payload, "name");
                if (!string.IsNullOrWhiteSpace(deviceId))
                {
                    client.DeviceId = deviceId.Length > 80 ? deviceId[..80] : deviceId;
                    if (!string.IsNullOrWhiteSpace(name)) client.Name = TrimName(name);
                    await RemoveDuplicatesAsync(client);
                }
                RefreshStatus();
                break;
            }
            case "start":
                client.Active = true;
                if (!_captureEnabled)
                {
                    client.Active = false;
                    await SendErrorAsync(client, "电脑端已关闭系统音频捕获，请先在电脑上开启。");
                }
                else
                {
                    StartCaptureIfNeeded();
                    await client.SendControlAsync(JsonSerializer.SerializeToUtf8Bytes(
                        new SpeakerStateMessage { Playing = true, Format = CurrentFormat }, Protocol.JsonOptions));
                }
                RefreshStatus();
                break;
            case "stop":
                client.Active = false;
                await client.SendControlAsync(JsonSerializer.SerializeToUtf8Bytes(
                    new SpeakerStateMessage { Playing = false }, Protocol.JsonOptions));
                if (ActiveCount == 0) StopCaptureIfIdle();
                RefreshStatus();
                break;
            case "ping":
            {
                var t = ProtocolJson.ReadDouble(payload, "t");
                if (t is not null)
                {
                    await client.SendControlAsync(JsonSerializer.SerializeToUtf8Bytes(
                        new PongMessage { T = t.Value }, Protocol.JsonOptions));
                }
                break;
            }
            case "pong":
                break;
            case "name":
            {
                var name = ProtocolJson.ReadString(payload, "name");
                if (!string.IsNullOrWhiteSpace(name))
                {
                    client.Name = TrimName(name);
                    RefreshStatus();
                }
                break;
            }
        }
    }

    private static string TrimName(string name)
    {
        var trimmed = name.Trim();
        return trimmed.Length > 40 ? trimmed[..40] : trimmed;
    }

    private string CurrentFormat => _efficient ? Protocol.Int16Le : Protocol.Float32Le;

    private void StopCaptureIfIdle()
    {
        if (ActiveCount > 0) return;
        if (_loopback.IsCapturing)
        {
            _loopback.Stop();
            Log.Info("8787 没有收听设备，已停止系统音频捕获。");
        }
        RefreshStatus();
    }

    private async Task RemoveDuplicatesAsync(SpeakerClient current)
    {
        List<SpeakerClient> duplicates;
        lock (_gate)
        {
            duplicates = _clients.Values
                .Where(client => client.Id != current.Id &&
                                 !string.IsNullOrEmpty(client.DeviceId) &&
                                 client.DeviceId == current.DeviceId)
                .ToList();
        }

        foreach (var duplicate in duplicates)
        {
            Log.Info($"音箱设备 {current.Name} 重复连接，踢除旧连接 {duplicate.Address}。");
            await RemoveClientAsync(duplicate, "同一设备的新连接已建立");
        }
    }

    internal async Task RemoveClientAsync(SpeakerClient client, string reason)
    {
        lock (_gate)
        {
            if (!_clients.Remove(client.Id)) return;
        }

        await client.CloseAsync(reason);
        if (ActiveCount == 0) StopCaptureIfIdle();
        RefreshStatus();
        Log.Info($"音箱设备已移除：{client.Name}（{client.Address}）");
    }

    private void BroadcastState(bool? playing, string? format)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            new SpeakerStateMessage { Playing = playing, Format = format },
            Protocol.JsonOptions);
        List<SpeakerClient> clients;
        lock (_gate) clients = _clients.Values.ToList();
        foreach (var client in clients)
        {
            client.TryQueueControl(bytes);
        }
    }

    private void BroadcastError(string message)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            new ErrorMessage { Message = message }, Protocol.JsonOptions);
        List<SpeakerClient> clients;
        lock (_gate) clients = _clients.Values.Where(client => client.Active).ToList();
        foreach (var client in clients)
        {
            client.TryQueueControl(bytes);
        }
    }

    private async Task SendErrorAsync(SpeakerClient client, string message)
    {
        await client.SendControlAsync(JsonSerializer.SerializeToUtf8Bytes(
            new ErrorMessage { Message = message }, Protocol.JsonOptions));
    }

    internal void RefreshStatus()
    {
        List<SpeakerDeviceStatus> devices;
        int active;
        lock (_gate)
        {
            devices = _clients.Values.Select(client => new SpeakerDeviceStatus(
                client.Id,
                client.DeviceId,
                client.Name,
                client.Address,
                client.Active,
                client.ConnectedAt)).ToList();
            active = _clients.Values.Count(client => client.Active);
        }

        var error = _loopback.Error;
        _state.UpdateSpeaker(builder =>
        {
            builder.Listening = _listening;
            builder.Port = _port;
            builder.CaptureEnabled = _captureEnabled;
            builder.Capturing = _loopback.IsCapturing;
            builder.CaptureMode = _loopback.IsCapturing ? _loopback.Mode : "idle";
            builder.CaptureError = error;
            builder.Efficient = _efficient;
            builder.SampleRate = MixEngine.SampleRate;
            builder.Channels = 2;
            builder.Format = CurrentFormat;
            builder.Devices = devices;
            builder.ActiveCount = active;
            builder.BytesPerSecond = _bytesPerSecond;
            builder.ExcludesOwnAudio = _loopback.ExcludesOwnAudio;
            builder.FeedbackWarning = _feedbackWarning;
        });
    }

    public object BuildHealth()
    {
        var snapshot = _state.Snapshot().Speaker;
        var devices = snapshot.Devices.Select(device => new
        {
            id = device.Id.ToString(),
            deviceId = device.DeviceId,
            name = device.Name,
            ip = device.Address,
            active = device.Active,
            since = device.ConnectedAt.ToString("o"),
        }).ToArray();

        return new
        {
            status = "ok",
            app = "AirMicSpeaker",
            platform = "windows",
            version = BuildInfo.Version,
            port = _port,
            devices = snapshot.Devices.Count,
            clients = snapshot.Devices.Count,
            active = snapshot.ActiveCount,
            efficient = snapshot.Efficient,
            captureEnabled = snapshot.CaptureEnabled,
            capturing = snapshot.Capturing,
            captureMode = snapshot.CaptureMode,
            excludesOwnAudio = snapshot.ExcludesOwnAudio,
            captureError = snapshot.CaptureError ?? string.Empty,
            sampleRate = MixEngine.SampleRate,
            channels = 2,
            format = CurrentFormat,
            bytesPerSecond = (int)Math.Round(snapshot.BytesPerSecond),
            deviceList = devices,
        };
    }

    /// <summary>One connected browser. Audio frames are queued and written by a single sender.</summary>
    internal sealed class SpeakerClient
    {
        private readonly SpeakerHub _hub;
        private readonly WebSocket _socket;
        private readonly CancellationTokenSource _lifetime;
        private readonly Channel<OutboundFrame> _outbound = Channel.CreateBounded<OutboundFrame>(
            new BoundedChannelOptions(48) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        private readonly SemaphoreSlim _closeLock = new(1, 1);
        private Task? _sender;
        private int _closed;
        private volatile bool _active;

        public SpeakerClient(SpeakerHub hub, Guid id, WebSocket socket, string address)
        {
            _hub = hub;
            Id = id;
            _socket = socket;
            Address = address;
            Name = $"设备 {address}";
            ConnectedAt = DateTimeOffset.Now;
            LastActivity = DateTime.UtcNow;
            _lifetime = new CancellationTokenSource();
        }

        public Guid Id { get; }
        public string Address { get; }
        public string Name { get; set; }
        public string DeviceId { get; set; } = string.Empty;
        public bool Active { get => _active; set => _active = value; }
        public DateTimeOffset ConnectedAt { get; }
        public DateTime LastActivity { get; private set; }

        public void Touch() => LastActivity = DateTime.UtcNow;

        public void Start()
        {
            _sender = Task.Run(() => SenderLoopAsync(_lifetime.Token));
        }

        public bool TryQueueAudio(byte[] data) =>
            _outbound.Writer.TryWrite(new OutboundFrame(data, WebSocketMessageType.Binary));

        public bool TryQueueControl(byte[] data) =>
            _outbound.Writer.TryWrite(new OutboundFrame(data, WebSocketMessageType.Text));

        public Task SendControlAsync(byte[] data)
        {
            // Control messages are rare; waiting is preferable to silently dropping them.
            return _outbound.Writer.WriteAsync(new OutboundFrame(data, WebSocketMessageType.Text), _lifetime.Token)
                .AsTask();
        }

        private async Task SenderLoopAsync(CancellationToken token)
        {
            try
            {
                await foreach (var frame in _outbound.Reader.ReadAllAsync(token))
                {
                    if (_socket.State != WebSocketState.Open) break;
                    await _socket.SendAsync(
                        new ArraySegment<byte>(frame.Data),
                        frame.Type,
                        endOfMessage: true,
                        token);
                }
            }
            catch (OperationCanceledException)
            {
                // closed
            }
            catch (WebSocketException)
            {
                // browser went away
            }
            catch (Exception ex)
            {
                Log.Warn($"发送到音箱设备失败：{ex.Message}");
            }
        }

        public async Task ReceiveLoopAsync()
        {
            var buffer = new byte[16 * 1024];
            using var memory = new MemoryStream();
            while (_socket.State == WebSocketState.Open)
            {
                memory.SetLength(0);
                WebSocketReceiveResult result;
                do
                {
                    result = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), _lifetime.Token);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    memory.Write(buffer, 0, result.Count);
                    if (memory.Length > 256 * 1024) throw new WebSocketException("消息过大");
                } while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    await _hub.HandleMessageAsync(this, memory.ToArray());
                }
            }
        }

        public async Task CloseAsync(string reason)
        {
            if (Interlocked.Exchange(ref _closed, 1) != 0) return;
            await _closeLock.WaitAsync();
            try
            {
                try
                {
                    if (_socket.State == WebSocketState.Open)
                    {
                        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(600));
                        await _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, reason, timeout.Token);
                    }
                }
                catch
                {
                    // browser already gone
                }

                _outbound.Writer.TryComplete();
                try { _socket.Dispose(); } catch { }
                try { _lifetime.Cancel(); } catch { }

                if (_sender is not null)
                {
                    try { await _sender.WaitAsync(TimeSpan.FromSeconds(1)); } catch { }
                }
            }
            finally
            {
                _lifetime.Dispose();
                _closeLock.Release();
            }
        }
    }

    private readonly record struct OutboundFrame(byte[] Data, WebSocketMessageType Type);
}
