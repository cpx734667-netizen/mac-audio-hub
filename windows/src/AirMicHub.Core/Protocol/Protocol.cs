using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Encodings.Web;

namespace AirMicHub.Core.Protocol;

/// <summary>
/// Wire contract shared with Resources/phone.html and the 8787 player page.
/// Field names are pinned explicitly: the browser pages are the source of truth and
/// must keep working unchanged.
/// </summary>
public static class Protocol
{
    public const int MaxPhones = 8;
    public const string Float32Le = "float32le";
    public const string Int16Le = "int16le";

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}

public sealed record MicReadyMessage
{
    [JsonPropertyName("type")] public string Type => "ready";
    [JsonPropertyName("sampleRate")] public int SampleRate { get; init; }
    [JsonPropertyName("targetBufferMs")] public int TargetBufferMs { get; init; } = 25;
    [JsonPropertyName("channel")] public int Channel { get; init; }
    [JsonPropertyName("server")] public string Server => BuildInfo.ServerTag;
}

public sealed record MicStatsMessage
{
    [JsonPropertyName("type")] public string Type => "stats";
    [JsonPropertyName("bufferMs")] public int BufferMs { get; init; }
    [JsonPropertyName("queueMs")] public int QueueMs { get; init; }
    [JsonPropertyName("outputLatencyMs")] public int OutputLatencyMs { get; init; }
    [JsonPropertyName("latencyMs")] public int LatencyMs { get; init; }
    [JsonPropertyName("rttMs")] public int RttMs { get; init; }
    [JsonPropertyName("kbps")] public int Kbps { get; init; }
    [JsonPropertyName("level")] public double Level { get; init; }
    [JsonPropertyName("sampleRate")] public int SampleRate { get; init; } = Audio.MixEngine.SampleRate;
    [JsonPropertyName("phones")] public int Phones { get; init; }
    [JsonPropertyName("underruns")] public int Underruns { get; init; }
}

public sealed record PingMessage
{
    [JsonPropertyName("type")] public string Type => "ping";
    [JsonPropertyName("t")] public double T { get; init; }
}

public sealed record PongMessage
{
    [JsonPropertyName("type")] public string Type => "pong";
    [JsonPropertyName("t")] public double T { get; init; }
}

public sealed record ErrorMessage
{
    [JsonPropertyName("type")] public string Type => "error";
    [JsonPropertyName("message")] public string Message { get; init; } = string.Empty;
}

public sealed record SpeakerReadyMessage
{
    [JsonPropertyName("type")] public string Type => "ready";
    [JsonPropertyName("sampleRate")] public int SampleRate { get; init; } = 48_000;
    [JsonPropertyName("channels")] public int Channels { get; init; } = 2;
    [JsonPropertyName("format")] public string Format { get; init; } = Protocol.Float32Le;
    [JsonPropertyName("deviceId")] public string DeviceId { get; init; } = string.Empty;
}

public sealed record SpeakerStateMessage
{
    [JsonPropertyName("type")] public string Type => "state";
    [JsonPropertyName("playing")] public bool? Playing { get; init; }
    [JsonPropertyName("format")] public string? Format { get; init; }
}

public static class ProtocolJson
{
    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Protocol.JsonOptions);

    public static byte[] SerializeBytes<T>(T value) =>
        JsonSerializer.SerializeToUtf8Bytes(value, Protocol.JsonOptions);

    /// <summary>Returns the "type" field of a text frame, or null when malformed.</summary>
    public static string? ReadType(ReadOnlySpan<byte> utf8)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            return document.RootElement.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String
                ? type.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string? ReadString(ReadOnlySpan<byte> utf8, string property)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            return document.RootElement.TryGetProperty(property, out var value) &&
                   value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static double? ReadDouble(ReadOnlySpan<byte> utf8, string property)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            if (!document.RootElement.TryGetProperty(property, out var value)) return null;
            return value.ValueKind switch
            {
                JsonValueKind.Number when value.TryGetDouble(out var number) => number,
                JsonValueKind.String when double.TryParse(value.GetString(), out var parsed) => parsed,
                _ => null,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
