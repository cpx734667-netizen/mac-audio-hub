using AirMicHub.Core.Lyrics;
using AirMicHub.Lyrics;
using Xunit;

namespace AirMicHub.Tests;

public class LyricsServiceTests
{
    [Fact]
    public async Task LoadsSyncedLyricsAndParses()
    {
        var service = new LyricsService(new FakeProvider(new LyricsDocument(
            "[00:01.00]hello\n[00:03.00]world", "hello\nworld")));

        await service.LoadForTrackAsync("Song", "Artist", "Album", 180);
        Assert.Equal(2, service.Lines.Count);
        Assert.Equal("歌词已同步", service.Status);
        Assert.Equal("LRCLIB", service.Source);
        Assert.Equal(0, service.CurrentIndex(2.0));
        Assert.Equal(1, service.CurrentIndex(3.2));
    }

    [Fact]
    public async Task FallsBackToPlainLyrics()
    {
        var service = new LyricsService(new FakeProvider(new LyricsDocument(null, "line one\nline two")));
        await service.LoadForTrackAsync("Song", "Artist", "", 0);
        Assert.Equal(2, service.Lines.Count);
        Assert.Contains("纯文本", service.Status);
    }

    [Fact]
    public async Task ReportsMissingLyricsWithoutThrowing()
    {
        var service = new LyricsService(new FakeProvider(null));
        await service.LoadForTrackAsync("Song", "Artist", "", 0);
        Assert.Empty(service.Lines);
        Assert.Contains("没有匹配", service.Status);
    }

    [Fact]
    public async Task ProviderFailureIsReportedAsUnavailable()
    {
        var service = new LyricsService(new ThrowingProvider());
        await service.LoadForTrackAsync("Song", "Artist", "", 0);
        Assert.Contains("歌词服务不可用", service.Status);
        Assert.Empty(service.Lines);
    }

    [Fact]
    public async Task SearchAndManualLrcSetSourceAndOffset()
    {
        var searchHit = new LyricsDocument("[00:05.00]found", null);
        var service = new LyricsService(new FakeProvider(searchHit, searchHit));
        Assert.True(await service.SearchAsync("Song", "Artist"));
        Assert.Equal("LRCLIB 搜索", service.Source);
        Assert.Single(service.Lines);

        Assert.True(service.LoadLrcText("[00:01.00]local", "my.lrc"));
        Assert.Equal("my.lrc", service.Source);
        Assert.Equal(0, service.OffsetSeconds);
        service.AdjustOffset(0.5);
        Assert.Equal(0.5, service.OffsetSeconds);
        service.AdjustOffset(100); // each nudge is clamped to 1 s
        Assert.Equal(1.5, service.OffsetSeconds);
        service.SetOffset(100);
        Assert.Equal(30, service.OffsetSeconds);

        Assert.False(service.LoadLrcText("just text", "plain.txt"));
        Assert.Contains("纯文本", service.Status);
    }

    [Fact]
    public async Task CachesRepeatedTrackLookups()
    {
        var provider = new CountingProvider();
        var service = new LyricsService(provider);
        await service.LoadForTrackAsync("Song", "Artist", "", 0);
        await service.LoadForTrackAsync("Song", "Artist", "", 0);
        Assert.Equal(1, provider.Calls);
    }

    [Fact]
    public async Task StaleTrackLoadCannotOverwriteNewerTrack()
    {
        var provider = new DelayedProvider();
        var service = new LyricsService(provider);

        var first = service.LoadForTrackAsync("First", "Artist", "", 0);
        await Task.Delay(50);
        await service.LoadForTrackAsync("Second", "Artist", "", 0);

        provider.CompleteFirst(new LyricsDocument("[00:01.00]first song", null));
        await first;

        var line = Assert.Single(service.Lines);
        Assert.Equal("second song", line.Text);
    }

    private sealed class DelayedProvider : ILyricsProvider
    {
        private readonly TaskCompletionSource<LyricsDocument?> _first = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<LyricsDocument?> GetAsync(string title, string artist, string album, double duration, CancellationToken cancellationToken = default)
        {
            return title == "First"
                ? _first.Task
                : Task.FromResult<LyricsDocument?>(new LyricsDocument("[00:01.00]second song", null));
        }

        public Task<LyricsDocument?> SearchAsync(string title, string artist, CancellationToken cancellationToken = default) =>
            Task.FromResult<LyricsDocument?>(null);

        public void CompleteFirst(LyricsDocument document) => _first.SetResult(document);
    }

    private sealed class FakeProvider : ILyricsProvider
    {
        private readonly LyricsDocument? _document;
        private readonly LyricsDocument? _searchDocument;

        public FakeProvider(LyricsDocument? document, LyricsDocument? searchDocument = null)
        {
            _document = document;
            _searchDocument = searchDocument;
        }

        public Task<LyricsDocument?> GetAsync(string title, string artist, string album, double duration, CancellationToken cancellationToken = default) =>
            Task.FromResult(_document);

        public Task<LyricsDocument?> SearchAsync(string title, string artist, CancellationToken cancellationToken = default) =>
            Task.FromResult(_searchDocument);
    }

    private sealed class ThrowingProvider : ILyricsProvider
    {
        public Task<LyricsDocument?> GetAsync(string title, string artist, string album, double duration, CancellationToken cancellationToken = default) =>
            throw new HttpRequestException("offline");

        public Task<LyricsDocument?> SearchAsync(string title, string artist, CancellationToken cancellationToken = default) =>
            throw new HttpRequestException("offline");
    }

    private sealed class CountingProvider : ILyricsProvider
    {
        public int Calls { get; private set; }

        public Task<LyricsDocument?> GetAsync(string title, string artist, string album, double duration, CancellationToken cancellationToken = default)
        {
            Calls++;
            return Task.FromResult<LyricsDocument?>(new LyricsDocument("[00:01.00]line", "line"));
        }

        public Task<LyricsDocument?> SearchAsync(string title, string artist, CancellationToken cancellationToken = default) =>
            Task.FromResult<LyricsDocument?>(null);
    }
}
