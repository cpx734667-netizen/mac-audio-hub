using System.Net.WebSockets;
using System.Text.Json;
using AirMicHub.Core.Audio;
using Xunit;

namespace AirMicHub.Tests;

public class MicServerTests
{
    [Fact]
    public async Task ServesPhonePageWorkletAndHealth()
    {
        await using var hub = await TestHub.StartAsync();
        using var client = TestHttp.CreateInsecureClient();

        var page = await client.GetStringAsync(hub.MicBaseUrl + "/");
        Assert.Contains("AirMic", page);
        Assert.Contains("pcm-worklet.js", page);
        Assert.Contains("第 ", page); // channel copy is still present
        Assert.DoesNotContain("Mac 在线", page);

        var worklet = await client.GetStringAsync(hub.MicBaseUrl + "/pcm-worklet.js");
        Assert.Contains("pcm-processor", worklet);
        Assert.Contains("sampleRate / 200", worklet);

        using var health = await TestHttp.GetJsonAsync(client, hub.MicBaseUrl + "/health");
        Assert.Equal("ok", health.RootElement.GetProperty("status").GetString());
        Assert.Equal("AirMic", health.RootElement.GetProperty("app").GetString());
        Assert.Equal(48000, health.RootElement.GetProperty("sampleRate").GetInt32());
        Assert.Equal(0, health.RootElement.GetProperty("phones").GetInt32());
    }

    [Fact]
    public async Task HelloReturnsReadyAndStatsReportPhone()
    {
        await using var hub = await TestHub.StartAsync();
        using var socket = await TestHttp.ConnectAsync($"wss://127.0.0.1:{hub.MicPort}/ws");
        await TestHttp.SendTextAsync(socket,
            "{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"TestPhone\",\"platform\":\"Test · Chrome\"}");

        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));
        Assert.Equal(48000, ready.RootElement.GetProperty("sampleRate").GetInt32());
        Assert.Equal(25, ready.RootElement.GetProperty("targetBufferMs").GetInt32());
        Assert.Equal(1, ready.RootElement.GetProperty("channel").GetInt32());
        Assert.Equal("AirMic", ready.RootElement.GetProperty("server").GetString());

        var pcm = new byte[240 * 2];
        for (var i = 0; i < 240; i++)
        {
            var value = (short)(Math.Sin(2 * Math.PI * 440 * i / 48000.0) * 12000);
            pcm[i * 2] = (byte)(value & 0xFF);
            pcm[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
        }
        await TestHttp.SendBinaryAsync(socket, pcm);

        using var stats = await TestHttp.WaitForTypeAsync(socket, "stats", TimeSpan.FromSeconds(5));
        Assert.Equal(1, stats.RootElement.GetProperty("phones").GetInt32());
        Assert.Equal(48000, stats.RootElement.GetProperty("sampleRate").GetInt32());
        Assert.True(stats.RootElement.GetProperty("bufferMs").GetInt32() >= 0);
        Assert.True(stats.RootElement.TryGetProperty("latencyMs", out _));

        using var http = TestHttp.CreateInsecureClient();
        using var health = await TestHttp.GetJsonAsync(http, hub.MicBaseUrl + "/health");
        Assert.Equal(1, health.RootElement.GetProperty("phones").GetInt32());
        var source = health.RootElement.GetProperty("sources")[0];
        Assert.Equal("TestPhone", source.GetProperty("name").GetString());
        Assert.Equal(1, source.GetProperty("channel").GetInt32());
    }

    [Fact]
    public async Task RejectsNinthPhoneWithLimitError()
    {
        await using var hub = await TestHub.StartAsync();
        var sockets = new List<ClientWebSocket>();
        try
        {
            for (var i = 1; i <= 8; i++)
            {
                var socket = await TestHttp.ConnectAsync($"wss://127.0.0.1:{hub.MicPort}/ws");
                sockets.Add(socket);
                await TestHttp.SendTextAsync(socket,
                    $"{{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"Phone{i}\",\"platform\":\"test\"}}");
                using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));
                Assert.Equal(i, ready.RootElement.GetProperty("channel").GetInt32());
            }

            using var ninth = await TestHttp.ConnectAsync($"wss://127.0.0.1:{hub.MicPort}/ws");
            await TestHttp.SendTextAsync(ninth,
                "{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"Phone9\",\"platform\":\"test\"}");
            using var error = await TestHttp.WaitForTypeAsync(ninth, "error", TimeSpan.FromSeconds(5));
            Assert.Contains("8", error.RootElement.GetProperty("message").GetString());

            using var http = TestHttp.CreateInsecureClient();
            using var health = await TestHttp.GetJsonAsync(http, hub.MicBaseUrl + "/health");
            Assert.Equal(8, health.RootElement.GetProperty("phones").GetInt32());
            Assert.Equal(8, health.RootElement.GetProperty("sources").GetArrayLength());
        }
        finally
        {
            foreach (var socket in sockets)
            {
                try { socket.Dispose(); } catch { }
            }
        }
    }

    [Fact]
    public async Task MutingASessionIsReflectedInHealth()
    {
        await using var hub = await TestHub.StartAsync();
        using var socket = await TestHttp.ConnectAsync($"wss://127.0.0.1:{hub.MicPort}/ws");
        await TestHttp.SendTextAsync(socket,
            "{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"MuteMe\",\"platform\":\"test\"}");
        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));

        using var http = TestHttp.CreateInsecureClient();
        using var before = await TestHttp.GetJsonAsync(http, hub.MicBaseUrl + "/health");
        var id = Guid.Parse(before.RootElement.GetProperty("sources")[0].GetProperty("id").GetString()!);
        Assert.True(hub.Server.Mic.SetMuted(id, true));

        using var after = await TestHttp.GetJsonAsync(http, hub.MicBaseUrl + "/health");
        Assert.True(after.RootElement.GetProperty("sources")[0].GetProperty("muted").GetBoolean());
    }

    [Fact]
    public async Task AudioFramesReachTheMixer()
    {
        await using var hub = await TestHub.StartAsync();
        using var socket = await TestHttp.ConnectAsync($"wss://127.0.0.1:{hub.MicPort}/ws");
        await TestHttp.SendTextAsync(socket,
            "{\"type\":\"hello\",\"sampleRate\":48000,\"name\":\"Audio\",\"platform\":\"test\"}");
        using var ready = await TestHttp.WaitForTypeAsync(socket, "ready", TimeSpan.FromSeconds(5));

        for (var frame = 0; frame < 20; frame++)
        {
            var pcm = new byte[240 * 2];
            for (var i = 0; i < 240; i++)
            {
                var value = (short)(Math.Sin(2 * Math.PI * 440 * (frame * 240 + i) / 48000.0) * 16000);
                pcm[i * 2] = (byte)(value & 0xFF);
                pcm[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
            }
            await TestHttp.SendBinaryAsync(socket, pcm);
        }

        await Task.Delay(400);
        var snapshot = hub.Mix.Snapshot();
        var source = Assert.Single(snapshot.Sources);
        Assert.True(snapshot.QueueMilliseconds > 0, "queue should hold received PCM");
        Assert.True(source.Level > 0.01f, $"level was {source.Level}");
    }
}
