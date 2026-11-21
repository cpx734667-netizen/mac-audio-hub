using AirMicHub.Core.Lyrics;
using Xunit;

namespace AirMicHub.Tests;

public class LrcParserTests
{
    [Fact]
    public void ParsesTimestampsAndSorts()
    {
        var lrc = "[00:12.50]second line\n[00:01.00]first line\n[00:20.00]third line\n";
        var lines = LrcParser.Parse(lrc);

        Assert.Equal(3, lines.Count);
        Assert.Equal("first line", lines[0].Text);
        Assert.Equal(1.0, lines[0].Time, 3);
        Assert.Equal(12.5, lines[1].Time, 3);
        Assert.Equal("third line", lines[2].Text);
    }

    [Fact]
    public void SupportsMultipleTimestampsPerLineAndMetadata()
    {
        var lrc = "[ar:Someone]\n[ti:Song]\n[00:05.00][00:10.00]chorus\n";
        var lines = LrcParser.Parse(lrc);

        Assert.Equal(2, lines.Count);
        Assert.All(lines, line => Assert.Equal("chorus", line.Text));
        Assert.Equal(5.0, lines[0].Time, 3);
        Assert.Equal(10.0, lines[1].Time, 3);
    }

    [Fact]
    public void IgnoresEmptyTextAndMalformedLines()
    {
        var lines = LrcParser.Parse("[00:01.00]\n[xx:yy]nothing\n[00:03.00]real");
        Assert.Single(lines);
        Assert.Equal("real", lines[0].Text);
    }

    [Fact]
    public void PlainLinesAndFindIndexRespectOffset()
    {
        var plain = LrcParser.PlainLines("a\n\nb\nc");
        Assert.Equal(3, plain.Count);
        Assert.Equal("a", plain[0].Text);

        var timed = LrcParser.Parse("[00:01.00]one\n[00:05.00]two\n[00:09.00]three");
        Assert.Equal(0, LrcParser.FindIndex(timed, 0));
        Assert.Equal(1, LrcParser.FindIndex(timed, 5.1));
        Assert.Equal(2, LrcParser.FindIndex(timed, 5.1, offset: 4));
        Assert.Equal(0, LrcParser.FindIndex(timed, 1, offset: -3));
    }

    [Fact]
    public void FormatsTimestamps()
    {
        Assert.Equal("01:05.0", LrcParser.FormatTimestamp(65));
        Assert.Equal("00:00.0", LrcParser.FormatTimestamp(-2));
    }
}
