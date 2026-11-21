using System.Globalization;
using System.Text.RegularExpressions;

namespace AirMicHub.Core.Lyrics;

public sealed record LyricLine(double Time, string Text);

/// <summary>
/// LRC parser compatible with the macOS reference implementation: multiple timestamps
/// per line, optional fraction digits, metadata tags ignored, sorted output.
/// </summary>
public static partial class LrcParser
{
    [GeneratedRegex(@"\[(\d{1,3}):(\d{1,2}(?:\.\d{1,3})?)\]", RegexOptions.Compiled)]
    private static partial Regex TimestampRegex();

    public static List<LyricLine> Parse(string? text)
    {
        var result = new List<LyricLine>();
        if (string.IsNullOrWhiteSpace(text)) return result;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;

            var matches = TimestampRegex().Matches(line);
            if (matches.Count == 0) continue;

            var last = matches[^1];
            var content = line[(last.Index + last.Length)..].Trim();
            if (content.Length == 0) continue;

            foreach (Match match in matches)
            {
                if (!double.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var minutes))
                    continue;
                if (!double.TryParse(match.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds))
                    continue;
                result.Add(new LyricLine(minutes * 60 + seconds, content));
            }
        }

        result.Sort((left, right) => left.Time.CompareTo(right.Time));
        return result;
    }

    /// <summary>Turns lyrics without timestamps into display-only lines.</summary>
    public static List<LyricLine> PlainLines(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return new List<LyricLine>();
        return text.Split('\n')
            .Select(line => line.Trim())
            .Where(line => line.Length > 0)
            .Select((line, index) => new LyricLine(-index, line))
            .ToList();
    }

    public static int FindIndex(IReadOnlyList<LyricLine> lines, double seconds, double offset = 0)
    {
        if (lines.Count == 0) return -1;
        var target = seconds + offset;
        var low = 0;
        var high = lines.Count - 1;
        var answer = 0;
        while (low <= high)
        {
            var mid = (low + high) / 2;
            if (lines[mid].Time <= target)
            {
                answer = mid;
                low = mid + 1;
            }
            else
            {
                high = mid - 1;
            }
        }
        return answer;
    }

    public static string FormatTimestamp(double seconds)
    {
        if (seconds < 0) seconds = 0;
        var minutes = (int)(seconds / 60);
        var rest = seconds - minutes * 60;
        return $"{minutes:00}:{rest:00.0}";
    }
}
