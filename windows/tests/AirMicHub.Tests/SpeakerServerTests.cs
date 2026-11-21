using System.Net.WebSockets;
using AirMicHub.Core;
using Xunit;

namespace AirMicHub.Tests;

public class SpeakerServerTests
{
    [Fact]
    public async Task ServesPlayerPageAndHealth()
    {
        await using var hub = await TestHub.StartAsync();
        using var client = TestHttp.CreateInsecureClient();

        var page = await client.GetStringAsync(hub.SpeakerBaseUrl + "/");
        Assert.Contains("电脑音箱", page);
        Assert.Contains("300", page); // 300 ms sync buffer copy preserved
        Assert.Contains("/ws", page);

        using var health = await TestHttp.GetJsonAsync(client, hub.SpeakerBaseUrl + "/health");
        Assert.Equal("ok", health.RootElement.GetProperty("status").GetString());
        Assert.Equal("AirMicSpeaker", health.RootElement.GetProperty("app").GetString());
        Assert.Equal(48000, health.RootElement.GetProperty("sampleRate").GetInt32());
        Assert.Equal(2, health.RootElement.GetProperty("channels").GetInt32());
        Assert.Equal("float32le", health.RootElement.GetProperty("format").GetString());
    }

    [Fact]
    public async Task ReadyDescribesFormatAndDevice()
    {
        await using var hub = await TestHub.StartAsync(builder => builder.CaptureEnabled = false);
        using var socket = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");

        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));
        Assert.Equal(48000, ready.RootElement.GetProperty("sampleRate").GetInt32());
        Assert.Equal(2, ready.RootElement.GetProperty("channels").GetInt32());
        Assert.Equal("float32le", ready.RootElement.GetProperty("format").GetString());
        Assert.False(string.IsNullOrWhiteSpace(ready.RootElement.GetProperty("deviceId").GetString()));
    }

    [Fact]
    public async Task StartIsRejectedWhenCaptureIsDisabled()
    {
        await using var hub = await TestHub.StartAsync(builder => builder.CaptureEnabled = false);
        using var socket = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");
        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));

        await TestHttp.SendTextAsync(socket, "{\"type\":\"device\",\"id\":\"dev-1\",\"name\":\"Phone\"}");
        await TestHttp.SendTextAsync(socket, "{\"type\":\"start\"}");

        using var error = await TestHttp.WaitForTypeAsync(socket, "error", TimeSpan.FromSeconds(5));
        Assert.Contains("关闭", error.RootElement.GetProperty("message").GetString());
    }

    [Fact]
    public async Task EfficientModeBroadcastsFormatState()
    {
        await using var hub = await TestHub.StartAsync(builder => builder.CaptureEnabled = false);
        using var socket = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");
        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));

        hub.Server.Speaker.SetEfficient(true);
        using var state = await TestHttp.WaitForTypeAsync(socket, "state", TimeSpan.FromSeconds(5));
        Assert.Equal("int16le", state.RootElement.GetProperty("format").GetString());

        using var http = TestHttp.CreateInsecureClient();
        using var health = await TestHttp.GetJsonAsync(http, hub.SpeakerBaseUrl + "/health");
        Assert.True(health.RootElement.GetProperty("efficient").GetBoolean());
        Assert.Equal("int16le", health.RootElement.GetProperty("format").GetString());
    }

    [Fact]
    public async Task SameDeviceIdReplacesOlderConnection()
    {
        await using var hub = await TestHub.StartAsync(builder => builder.CaptureEnabled = false);
        using var http = TestHttp.CreateInsecureClient();

        using var first = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");
        using var firstReady = await TestHttp.WaitForTypeAsync(first, "ready", TimeSpan.FromSeconds(5));
        await TestHttp.SendTextAsync(first, "{\"type\":\"device\",\"id\":\"same-phone\",\"name\":\"Phone\"}");
        await WaitForDeviceIdAsync(http, hub, "same-phone", expectedCount: 1, TimeSpan.FromSeconds(5));

        using var second = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");
        using var secondReady = await TestHttp.WaitForTypeAsync(second, "ready", TimeSpan.FromSeconds(5));
        await TestHttp.SendTextAsync(second, "{\"type\":\"device\",\"id\":\"same-phone\",\"name\":\"Phone\"}");

        // The server kicks the older socket. Depending on timing the client observes a close
        // frame or a socket error; both mean the duplicate was removed.
        var closed = false;
        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (DateTime.UtcNow < deadline)
            {
                var message = await TestHttp.ReceiveAsync(first, deadline - DateTime.UtcNow);
                if (message.Type == WebSocketMessageType.Close) { closed = true; break; }
            }
        }
        catch (Exception)
        {
            closed = true;
        }

        Assert.True(closed, "older connection should be closed when the same device reconnects");

        await WaitForDeviceCountAsync(http, hub, expectedCount: 1, TimeSpan.FromSeconds(5));
        using var health = await TestHttp.GetJsonAsync(http, hub.SpeakerBaseUrl + "/health");
        Assert.Equal(1, health.RootElement.GetProperty("devices").GetInt32());
        Assert.Equal("same-phone", health.RootElement.GetProperty("deviceList")[0].GetProperty("deviceId").GetString());
    }

    private static async Task WaitForDeviceIdAsync(
        HttpClient http,
        TestHub hub,
        string deviceId,
        int expectedCount,
        TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            using var health = await TestHttp.GetJsonAsync(http, hub.SpeakerBaseUrl + "/health");
            var devices = health.RootElement.GetProperty("deviceList");
            if (devices.GetArrayLength() == expectedCount &&
                devices[0].GetProperty("deviceId").GetString() == deviceId)
            {
                return;
            }
            await Task.Delay(100);
        }
        throw new TimeoutException("设备 ID 未在预期时间内注册");
    }

    private static async Task WaitForDeviceCountAsync(HttpClient http, TestHub hub, int expectedCount, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            using var health = await TestHttp.GetJsonAsync(http, hub.SpeakerBaseUrl + "/health");
            if (health.RootElement.GetProperty("devices").GetInt32() == expectedCount) return;
            await Task.Delay(100);
        }
        throw new TimeoutException("设备数量未在预期时间内稳定");
    }

    [Fact]
    public async Task StartWithCaptureEnabledStartsCaptureOrReportsError()
    {
        await using var hub = await TestHub.StartAsync();
        using var socket = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");
        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));
        await TestHttp.SendTextAsync(socket, "{\"type\":\"device\",\"id\":\"dev-audio\",\"name\":\"Phone\"}");
        await TestHttp.SendTextAsync(socket, "{\"type\":\"start\"}");

        var sawState = false;
        var sawError = false;
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline && !sawState && !sawError)
        {
            var message = await TestHttp.ReceiveAsync(socket, TimeSpan.FromSeconds(5));
            if (message.Type != WebSocketMessageType.Text) continue;
            var text = System.Text.Encoding.UTF8.GetString(message.Payload);
            if (text.Contains("\"type\":\"state\"")) sawState = true;
            if (text.Contains("\"type\":\"error\"")) sawError = true;
        }

        Assert.True(sawState || sawError, "start must produce state or an explicit error");

        using var http = TestHttp.CreateInsecureClient();
        using var health = await TestHttp.GetJsonAsync(http, hub.SpeakerBaseUrl + "/health");
        Assert.True(health.RootElement.TryGetProperty("captureMode", out var mode));
        Assert.NotNull(mode.GetString());
        Assert.True(health.RootElement.TryGetProperty("excludesOwnAudio", out _));
    }

    [Fact]
    public async Task BothServicesServeAtTheSameTime()
    {
        await using var hub = await TestHub.StartAsync();

        using var mic = await TestHttp.ConnectAsync($"wss://127.0.0.1:{hub.MicPort}/ws");
        await TestHttp.SendTextAsync(mic,
            "{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"MicPhone\",\"platform\":\"test\"}");
        using var micReady = await TestHttp.WaitForTypeAsync(mic, "ready", TimeSpan.FromSeconds(5));

        using var speaker = await TestHttp.ConnectAsync($"ws://127.0.0.1:{hub.SpeakerPort}/ws");
        using var speakerReady = await TestHttp.WaitForTypeAsync(speaker, "ready", TimeSpan.FromSeconds(5));

        using var http = TestHttp.CreateInsecureClient();
        using var micHealth = await TestHttp.GetJsonAsync(http, hub.MicBaseUrl + "/health");
        using var speakerHealth = await TestHttp.GetJsonAsync(http, hub.SpeakerBaseUrl + "/health");
        Assert.Equal(1, micHealth.RootElement.GetProperty("phones").GetInt32());
        Assert.Equal("ok", speakerHealth.RootElement.GetProperty("status").GetString());
        Assert.True(hub.Server.IsRunning);

        var snapshot = hub.State.Snapshot();
        Assert.True(snapshot.Mic.Listening);
        Assert.True(snapshot.Speaker.Listening);
        Assert.Equal(hub.MicPort, snapshot.Mic.Port);
        Assert.Equal(hub.SpeakerPort, snapshot.Speaker.Port);
    }
}
