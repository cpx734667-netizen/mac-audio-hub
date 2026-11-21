using System.Net.WebSockets;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using AirMicHub.Core;
using AirMicHub.Core.Audio;
using AirMicHub.Core.Protocol;
using AirMicHub.Core.State;

namespace AirMicHub.Server;

/// <summary>
/// 8765 phone microphone hub: HTTPS page, /health and the WSS protocol from
/// Resources/phone.html. Each phone gets channel 1..8, its own 5 ms PCM source queue and a
/// stats/ping loop. The heavy lifting lives in <see cref="MixEngine"/>.
/// </summary>
public sealed class MicHub : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, MicSession> _sessions = new();
    private readonly MixEngine _mix;
    private readonly HubState _state;

    private CancellationTokenSource? _cts;
    private Task? _statusTask;
    private bool _listening;
    private int _port = 8765;
    private long _statsTick;

    public MicHub(MixEngine mix, HubState state)
    {
        _mix = mix;
        _state = state;
    }

    public int Port => _port;
    public bool Listening => _listening;
    public int PhoneCount
    {
        get
        {
            lock (_gate) return _sessions.Values.Count(session => session.Hello);
        }
    }

    internal CancellationToken Token => _cts?.Token ?? CancellationToken.None;

    public void Start(int port)
    {
        _port = port;
        _listening = true;
        _cts = new CancellationTokenSource();
        _statusTask = Task.Run(() => StatusLoopAsync(_cts.Token));
        _state.UpdateMic(builder =>
        {
            builder.Listening = true;
            builder.Port = port;
            builder.Error = null;
        });
        Log.Info($"手机麦克风服务已启动：https://0.0.0.0:{port}/");
    }

    public async Task StopAsync()
    {
        _listening = false;
        try { _cts?.Cancel(); } catch { }
        if (_statusTask is not null)
        {
            try { await _statusTask; } catch (OperationCanceledException) { } catch (Exception ex) { Log.Warn($"麦克风状态循环退出异常：{ex.Message}"); }
        }

        List<MicSession> sessions;
        lock (_gate)
        {
            sessions = _sessions.Values.ToList();
            _sessions.Clear();
        }

        foreach (var session in sessions)
        {
            await session.CloseAsync("服务停止");
            _mix.RemoveSource(session.Id);
        }

        _state.UpdateMic(builder =>
        {
            builder.Listening = false;
            builder.Phones = Array.Empty<MicPhoneStatus>();
            builder.BufferMilliseconds = 0;
            builder.QueueMilliseconds = 0;
            builder.LatencyMilliseconds = 0;
            builder.Kbps = 0;
            builder.Level = 0;
        });
        Log.Info("8765 手机麦克风服务已停止。");
    }

    public async ValueTask DisposeAsync() => await StopAsync();

    public async Task AcceptAsync(HttpContext context)
    {
        var socket = await context.WebSockets.AcceptWebSocketAsync();
        var id = Guid.NewGuid();
        var session = new MicSession(
            this,
            id,
            socket,
            context.Connection.RemoteIpAddress?.ToString() ?? "未知",
            context.Request.Headers.UserAgent.ToString());
        lock (_gate)
        {
            _sessions[id] = session;
        }

        Log.Info($"手机已连接：{session.Address}（UA: {Truncate(session.UserAgent, 80)}）");
        try
        {
            await session.RunAsync();
        }
        catch (Exception ex)
        {
            Log.Warn($"手机连接异常退出（{session.Address}）：{ex.Message}");
        }
        finally
        {
            await RemoveSessionAsync(session);
        }
    }

    private async Task RemoveSessionAsync(MicSession session)
    {
        lock (_gate)
        {
            _sessions.Remove(session.Id);
        }
        _mix.RemoveSource(session.Id);
        await session.CloseAsync("连接关闭");
        RefreshStatus();
        Log.Info($"手机已断开：{session.Address}（第 {session.Channel} 路）");
    }

    public bool SetMuted(Guid sessionId, bool muted)
    {
        lock (_gate)
        {
            if (!_sessions.ContainsKey(sessionId)) return false;
        }
        _mix.SetMuted(sessionId, muted);
        RefreshStatus();
        return true;
    }

    internal bool TryRegister(MicSession session, string name, string platform, double sampleRate, out int channel, out string? error)
    {
        channel = 0;
        error = null;
        lock (_gate)
        {
            var active = _sessions.Values.Where(item => item.Hello).ToList();
            if (active.Count >= Protocol.MaxPhones)
            {
                error = "同时连接的手机已达上限（8 台）";
                return false;
            }

            var used = active.Select(item => item.Channel).ToHashSet();
            var candidate = 1;
            while (used.Contains(candidate)) candidate++;
            channel = candidate;

            session.Name = name;
            session.Platform = platform;
            session.SampleRate = sampleRate;
            session.Channel = candidate;
            session.Hello = true;
            _mix.AddSource(name, sampleRate, id: session.Id);
        }

        RefreshStatus();
        return true;
    }

    internal async Task UnregisterAsync(MicSession session)
    {
        _mix.RemoveSource(session.Id);
        RefreshStatus();
        await Task.CompletedTask;
    }

    internal Task SendJsonAsync<T>(MicSession session, T message, CancellationToken token = default)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(message, Protocol.JsonOptions);
        return session.SendAsync(bytes, WebSocketMessageType.Text, token);
    }

    internal Task CloseSessionAsync(MicSession session, string reason)
    {
        lock (_gate)
        {
            _sessions.Remove(session.Id);
        }
        _mix.RemoveSource(session.Id);
        return session.CloseAsync(reason);
    }

    private async Task StatusLoopAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(600));
        try
        {
            while (await timer.WaitForNextTickAsync(token))
            {
                RefreshStatus();
                _statsTick++;
                if (_statsTick % 2 != 0) continue; // stats every ~1.2 s

                List<MicSession> sessions;
                lock (_gate) sessions = _sessions.Values.Where(session => session.Hello).ToList();

                foreach (var session in sessions)
                {
                    try
                    {
                        await SendStatsAsync(session, token);
                    }
                    catch (Exception ex)
                    {
                        Log.Warn($"发送 stats 失败（{session.Address}）：{ex.Message}");
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
    }

    private async Task SendStatsAsync(MicSession session, CancellationToken token)
    {
        var snapshot = _mix.Snapshot();
        var interval = Math.Max(0.2, (DateTime.UtcNow - session.LastStatsAt).TotalSeconds);
        var measuredKbps = session.BytesSinceStats * 8.0 / 1000.0 / interval;
        session.Kbps = session.Kbps <= 0 ? measuredKbps : session.Kbps * 0.65 + measuredKbps * 0.35;
        session.BytesSinceStats = 0;
        session.LastStatsAt = DateTime.UtcNow;

        var bufferMs = (int)Math.Round(snapshot.BufferMilliseconds);
        var latency = (int)Math.Round(bufferMs + session.RttMilliseconds / 2.0);
        await SendJsonAsync(session, new MicStatsMessage
        {
            BufferMs = bufferMs,
            QueueMs = (int)Math.Round(snapshot.QueueMilliseconds),
            OutputLatencyMs = (int)Math.Round(snapshot.OutputLatencyMilliseconds),
            LatencyMs = latency,
            RttMs = (int)Math.Round(session.RttMilliseconds),
            Kbps = (int)Math.Round(session.Kbps),
            Level = float.IsFinite(snapshot.Level) ? snapshot.Level : 0,
            Phones = PhoneCount,
            Underruns = snapshot.Underruns,
        }, token);

        if (_statsTick % 6 == 0)
        {
            await SendJsonAsync(session, new PingMessage
            {
                T = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            }, token);
        }
    }

    internal void RefreshStatus()
    {
        var snapshot = _mix.Snapshot();
        List<MicSession> sessions;
        lock (_gate) sessions = _sessions.Values.Where(session => session.Hello).ToList();

        var phones = new List<MicPhoneStatus>();
        foreach (var session in sessions.OrderBy(session => session.Channel))
        {
            var source = snapshot.Sources.FirstOrDefault(item => item.Id == session.Id);
            phones.Add(new MicPhoneStatus(
                session.Id,
                session.Channel,
                session.Name,
                session.Platform,
                session.Address,
                source?.Level ?? 0,
                source?.QueueMilliseconds ?? 0,
                source?.Muted ?? false,
                session.Kbps));
        }

        var totalKbps = sessions.Sum(session => session.Kbps);
        var averageRtt = sessions.Count == 0 ? 0 : sessions.Average(session => session.RttMilliseconds);
        var bufferMs = snapshot.BufferMilliseconds;
        _state.UpdateMic(builder =>
        {
            builder.Listening = _listening;
            builder.Port = _port;
            builder.Phones = phones;
            builder.BufferMilliseconds = bufferMs;
            builder.QueueMilliseconds = snapshot.QueueMilliseconds;
            builder.OutputLatencyMilliseconds = snapshot.OutputLatencyMilliseconds;
            builder.LatencyMilliseconds = bufferMs + averageRtt / 2.0;
            builder.Kbps = totalKbps;
            builder.Underruns = snapshot.Underruns;
            builder.DroppedFrames = snapshot.DroppedFrames;
            builder.Level = snapshot.Level;
            builder.SampleRate = MixEngine.SampleRate;
            builder.TestTonePlaying = snapshot.TestTonePlaying;
            builder.EngineRunning = snapshot.EngineRunning;
        });
    }

    public object BuildHealth()
    {
        var snapshot = _state.Snapshot().Mic;
        var mix = _mix.Snapshot();
        List<MicSession> sessions;
        lock (_gate) sessions = _sessions.Values.Where(session => session.Hello).ToList();

        var sources = sessions.OrderBy(session => session.Channel).Select(session =>
        {
            var source = mix.Sources.FirstOrDefault(item => item.Id == session.Id);
            return new
            {
                id = session.Id.ToString(),
                name = session.Name,
                platform = session.Platform,
                channel = session.Channel,
                sampleRate = (int)Math.Round(session.SampleRate),
                level = Math.Round(source?.Level ?? 0f, 4),
                queueMs = (int)Math.Round(source?.QueueMilliseconds ?? 0),
                muted = source?.Muted ?? false,
            };
        }).ToArray();

        return new
        {
            status = "ok",
            app = BuildInfo.ServerTag,
            platform = "windows",
            version = BuildInfo.Version,
            port = _port,
            clients = _sessions.Count,
            phones = sessions.Count,
            streaming = sessions.Count > 0,
            bufferMs = (int)Math.Round(snapshot.BufferMilliseconds),
            pendingMs = 0,
            aheadMs = 0,
            queueMs = (int)Math.Round(snapshot.QueueMilliseconds),
            underruns = snapshot.Underruns,
            sampleRate = MixEngine.SampleRate,
            outputLatencyMs = (int)Math.Round(snapshot.OutputLatencyMilliseconds),
            engine = snapshot.EngineRunning,
            player = snapshot.EngineRunning,
            targetMs = 25,
            silentChunks = 0,
            droppedFrames = snapshot.DroppedFrames,
            totalKbps = (int)Math.Round(snapshot.Kbps),
            level = Math.Round(snapshot.Level, 4),
            outputDevice = snapshot.OutputDeviceName,
            localMic = new
            {
                enabled = snapshot.LocalMicEnabled,
                active = snapshot.LocalMicActive,
                device = snapshot.LocalMicDeviceName,
                error = snapshot.LocalMicError,
            },
            sources,
        };
    }

    private static string Truncate(string value, int length) =>
        value.Length <= length ? value : value[..length] + "…";

    /// <summary>One phone. Owns the WSS socket and its receive loop.</summary>
    internal sealed class MicSession
    {
        private readonly MicHub _hub;
        private readonly WebSocket _socket;
        private readonly SemaphoreSlim _sendLock = new(1, 1);
        private readonly CancellationTokenSource _lifetime;
        private int _closed;
        private bool _closeReceived;

        public MicSession(MicHub hub, Guid id, WebSocket socket, string address, string userAgent)
        {
            _hub = hub;
            Id = id;
            _socket = socket;
            Address = address;
            UserAgent = userAgent;
            _lifetime = CancellationTokenSource.CreateLinkedTokenSource(hub.Token);
            LastStatsAt = DateTime.UtcNow;
        }

        public Guid Id { get; }
        public string Address { get; }
        public string UserAgent { get; }
        public string Name { get; set; } = "手机麦克风";
        public string Platform { get; set; } = "手机浏览器";
        public int Channel { get; set; }
        public double SampleRate { get; set; } = 48_000;
        public bool Hello { get; set; }
        public bool Muted { get; set; }
        public long BytesSinceStats { get; set; }
        public DateTime LastStatsAt { get; set; }
        public double RttMilliseconds { get; set; }
        public double Kbps { get; set; }
        public float Level { get; set; }
        public double QueueMilliseconds { get; set; }

        public async Task RunAsync()
        {
            using var receiveTimeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
            receiveTimeout.CancelAfter(TimeSpan.FromSeconds(8));

            try
            {
                while (_socket.State == WebSocketState.Open && !_lifetime.IsCancellationRequested)
                {
                    var message = await ReceiveMessageAsync(receiveTimeout.Token);
                    if (message is null) break;

                    if (message.Value.Type == WebSocketMessageType.Close)
                    {
                        _closeReceived = true;
                        break;
                    }
                    if (message.Value.Type == WebSocketMessageType.Text)
                    {
                        if (!await HandleTextAsync(message.Value.Payload)) break;
                        if (Hello)
                        {
                            receiveTimeout.CancelAfter(Timeout.InfiniteTimeSpan);
                        }
                    }
                    else if (message.Value.Type == WebSocketMessageType.Binary)
                    {
                        if (!Hello) continue;
                        BytesSinceStats += message.Value.Payload.Length;
                        _hub._mix.Enqueue(Id, message.Value.Payload, SampleRate);
                    }
                }
            }
            catch (OperationCanceledException) when (!_lifetime.IsCancellationRequested)
            {
                Log.Warn($"手机 {Address} 在 8 秒内没有发送 hello，已断开。");
            }
            catch (WebSocketException ex)
            {
                Log.Info($"手机 {Address} WebSocket 已断开：{ex.Message}");
            }
        }

        private async Task<bool> HandleTextAsync(byte[] payload)
        {
            var type = ProtocolJson.ReadType(payload);
            if (type is null) return true;

            switch (type)
            {
                case "hello":
                {
                    if (Hello) return true;
                    var rate = ProtocolJson.ReadDouble(payload, "sampleRate") ?? 48_000;
                    rate = Math.Clamp(rate, 8_000, 192_000);
                    var name = (ProtocolJson.ReadString(payload, "name") ?? string.Empty).Trim();
                    if (name.Length == 0) name = "手机麦克风";
                    if (name.Length > 40) name = name[..40];
                    var platform = ProtocolJson.ReadString(payload, "platform") ?? "手机浏览器";
                    if (platform.Length > 60) platform = platform[..60];

                    if (!_hub.TryRegister(this, name, platform, rate, out var channel, out var error))
                    {
                        await _hub.SendJsonAsync(this, new ErrorMessage { Message = error ?? "连接被拒绝" });
                        await Task.Delay(200);
                        return false;
                    }

                    await _hub.SendJsonAsync(this, new MicReadyMessage
                    {
                        SampleRate = (int)Math.Round(rate),
                        Channel = channel,
                    });
                    Log.Info($"手机已接入：{name} / {platform} / 第 {channel} 路 / {rate:0} Hz");
                    return true;
                }
                case "ping":
                {
                    var t = ProtocolJson.ReadDouble(payload, "t");
                    if (t is not null)
                    {
                        await _hub.SendJsonAsync(this, new PongMessage { T = t.Value });
                    }
                    return true;
                }
                case "pong":
                {
                    var t = ProtocolJson.ReadDouble(payload, "t");
                    if (t is not null)
                    {
                        var measured = Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - t.Value);
                        RttMilliseconds = RttMilliseconds <= 0
                            ? measured
                            : RttMilliseconds * 0.7 + measured * 0.3;
                    }
                    return true;
                }
                case "bye":
                    return false;
                default:
                    return true;
            }
        }

        private async Task<(WebSocketMessageType Type, byte[] Payload)?> ReceiveMessageAsync(CancellationToken token)
        {
            var buffer = new byte[64 * 1024];
            using var memory = new MemoryStream();
            WebSocketMessageType messageType = WebSocketMessageType.Text;
            while (true)
            {
                var result = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
                if (result.MessageType == WebSocketMessageType.Close) return null;
                messageType = result.MessageType;
                memory.Write(buffer, 0, result.Count);
                if (memory.Length > 512 * 1024)
                {
                    throw new WebSocketException("消息过大，连接已关闭。");
                }
                if (result.EndOfMessage) break;
            }

            return (messageType, memory.ToArray());
        }

        public async Task SendAsync(byte[] payload, WebSocketMessageType type, CancellationToken token = default)
        {
            if (_socket.State != WebSocketState.Open) return;
            await _sendLock.WaitAsync(token);
            try
            {
                if (_socket.State == WebSocketState.Open)
                {
                    await _socket.SendAsync(
                        new ArraySegment<byte>(payload),
                        type,
                        endOfMessage: true,
                        token == default ? _lifetime.Token : token);
                }
            }
            finally
            {
                _sendLock.Release();
            }
        }

        public async Task CloseAsync(string reason)
        {
            if (Interlocked.Exchange(ref _closed, 1) != 0) return;
            try
            {
                if (_socket.State == WebSocketState.Open || _socket.State == WebSocketState.CloseReceived)
                {
                    using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(800));
                    if (_closeReceived)
                    {
                        await _socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, reason, timeout.Token);
                    }
                    else
                    {
                        await _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, reason, timeout.Token);
                    }
                }
            }
            catch
            {
                // The browser may already be gone.
            }
            finally
            {
                try { _socket.Dispose(); } catch { }
                try { _lifetime.Cancel(); } catch { }
                _lifetime.Dispose();
                _sendLock.Dispose();
                await UnregisterAsync();
            }
        }

        private async Task UnregisterAsync()
        {
            _hub._mix.RemoveSource(Id);
            await Task.CompletedTask;
        }
    }
}
