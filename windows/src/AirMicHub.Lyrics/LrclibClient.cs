using System.Globalization;
using System.Net;
using System.Text.Json;
using AirMicHub.Core;

namespace AirMicHub.Lyrics;

public sealed record LyricsDocument(string? SyncedLyrics, string? PlainLyrics, string Title = "", string Artist = "");

public interface ILyricsProvider
{
    Task<LyricsDocument?> GetAsync(
        string title,
        string artist,
        string album,
        double durationSeconds,
        CancellationToken cancellationToken = default);

    Task<LyricsDocument?> SearchAsync(string title, string artist, CancellationToken cancellationToken = default);
}

/// <summary>LRCLIB client (https://lrclib.net). Exact match first, then free-text search.</summary>
public sealed class LrclibClient : ILyricsProvider
{
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("AirMicHub/1.0 (Windows; local karaoke companion)");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        return client;
    }

    public async Task<LyricsDocument?> GetAsync(
        string title,
        string artist,
        string album,
        double durationSeconds,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(title)) return null;

        var query = new List<string> { $"track_name={Uri.EscapeDataString(title.Trim())}" };
        if (!string.IsNullOrWhiteSpace(artist)) query.Add($"artist_name={Uri.EscapeDataString(artist.Trim())}");
        if (!string.IsNullOrWhiteSpace(album)) query.Add($"album_name={Uri.EscapeDataString(album.Trim())}");
        if (durationSeconds > 0) query.Add($"duration={Math.Round(durationSeconds).ToString(CultureInfo.InvariantCulture)}");

        using var response = await Http.GetAsync(
            "https://lrclib.net/api/get?" + string.Join("&", query),
            cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"LRCLIB 返回 {(int)response.StatusCode}");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        var root = document.RootElement;
        return new LyricsDocument(
            root.TryGetProperty("syncedLyrics", out var synced) && synced.ValueKind == JsonValueKind.String
                ? synced.GetString()
                : null,
            root.TryGetProperty("plainLyrics", out var plain) && plain.ValueKind == JsonValueKind.String
                ? plain.GetString()
                : null,
            root.TryGetProperty("trackName", out var track) && track.ValueKind == JsonValueKind.String
                ? track.GetString() ?? string.Empty
                : string.Empty,
            root.TryGetProperty("artistName", out var artistName) && artistName.ValueKind == JsonValueKind.String
                ? artistName.GetString() ?? string.Empty
                : string.Empty);
    }

    public async Task<LyricsDocument?> SearchAsync(
        string title,
        string artist,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(title)) return null;
        var query = string.IsNullOrWhiteSpace(artist) ? title.Trim() : $"{title.Trim()} {artist.Trim()}";
        using var response = await Http.GetAsync(
            "https://lrclib.net/api/search?q=" + Uri.EscapeDataString(query),
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"LRCLIB 搜索返回 {(int)response.StatusCode}");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        if (document.RootElement.ValueKind != JsonValueKind.Array) return null;

        foreach (var item in document.RootElement.EnumerateArray())
        {
            var synced = item.TryGetProperty("syncedLyrics", out var syncedText) &&
                         syncedText.ValueKind == JsonValueKind.String
                ? syncedText.GetString()
                : null;
            var plain = item.TryGetProperty("plainLyrics", out var plainText) &&
                        plainText.ValueKind == JsonValueKind.String
                ? plainText.GetString()
                : null;
            if (string.IsNullOrWhiteSpace(synced) && string.IsNullOrWhiteSpace(plain)) continue;
            return new LyricsDocument(
                synced,
                plain,
                item.TryGetProperty("trackName", out var track) ? track.GetString() ?? string.Empty : string.Empty,
                item.TryGetProperty("artistName", out var artistName) ? artistName.GetString() ?? string.Empty : string.Empty);
        }

        return null;
    }
}
