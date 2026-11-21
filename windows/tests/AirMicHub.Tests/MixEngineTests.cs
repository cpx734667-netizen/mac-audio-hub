using AirMicHub.Core.Audio;
using Xunit;

namespace AirMicHub.Tests;

public class MixEngineTests
{
    [Fact]
    public void EnforcesThirtyMillisecondQueueCeiling()
    {
        var engine = new MixEngine();
        var id = engine.AddSource("phone", 48_000, prebufferMilliseconds: 10, maxQueueMilliseconds: 30);
        var samples = new float[48_000];
        for (var i = 0; i < samples.Length; i++) samples[i] = 0.1f;

        engine.Enqueue(id, samples, 48_000);
        var snapshot = engine.Snapshot();

        Assert.True(snapshot.QueueMilliseconds <= 30.5, $"queue was {snapshot.QueueMilliseconds} ms");
        Assert.True(snapshot.DroppedFrames > 40_000, $"dropped {snapshot.DroppedFrames}");
    }

    [Fact]
    public void PrebuffersTenMillisecondsBeforePlaying()
    {
        var engine = new MixEngine();
        engine.SetVolume(1f);
        var id = engine.AddSource("phone", 48_000);
        var pcm = MakeSine(480, 48_000, amplitude: 0.5f);

        var output = new float[240 * 2];
        engine.Read(output, 240);
        Assert.All(output, value => Assert.Equal(0f, value));

        engine.Enqueue(id, pcm, 48_000);
        engine.Read(output, 240);
        Assert.Contains(output, value => Math.Abs(value) > 0.01f);
    }

    [Fact]
    public void NormalizesMultipleSources()
    {
        var engine = new MixEngine();
        engine.SetVolume(1f);
        var first = engine.AddSource("a", 48_000);
        var second = engine.AddSource("b", 48_000);
        engine.Enqueue(first, Enumerable.Repeat(0.5f, 480).ToArray(), 48_000);
        engine.Enqueue(second, Enumerable.Repeat(0.5f, 480).ToArray(), 48_000);

        var output = new float[240 * 2];
        engine.Read(output, 240);

        // Two correlated sources each scaled by 1/sqrt(2) add to about 0.707.
        var expected = 0.5f * 2f / MathF.Sqrt(2f);
        Assert.InRange(output[0], expected - 0.01f, expected + 0.01f);
        Assert.Equal(output[0], output[1], 4);
    }

    [Fact]
    public void Resamples44k1To48k()
    {
        var engine = new MixEngine();
        engine.SetVolume(1f);
        var id = engine.AddSource("phone", 44_100);
        // 10 ms of 44.1 kHz audio becomes about 10.9 ms at 48 kHz.
        engine.Enqueue(id, MakeSine(441, 44_100, amplitude: 0.4f), 44_100);

        var snapshot = engine.Snapshot();
        var source = Assert.Single(snapshot.Sources);
        Assert.Equal(44_100, source.InputRate, 0);
        Assert.InRange(source.QueueMilliseconds, 8, 14);

        var oneSecond = MakeSine(44_100, 44_100, amplitude: 0.4f);
        var resampled = StreamingResampler.Resample(oneSecond, 44_100, 48_000, 1);
        Assert.InRange(resampled.Length, 47_900, 48_200);
    }

    [Fact]
    public void TestTonePlaysWithoutAnySource()
    {
        var engine = new MixEngine();
        engine.SetVolume(1f);
        engine.TriggerTestTone();

        var output = new float[240 * 2];
        engine.Read(output, 240);
        Assert.Contains(output, value => Math.Abs(value) > 0.01f);
        Assert.True(engine.TestTonePlaying);
    }

    [Fact]
    public void MutedSourceDoesNotContribute()
    {
        var engine = new MixEngine();
        engine.SetVolume(1f);
        var id = engine.AddSource("a", 48_000);
        engine.Enqueue(id, Enumerable.Repeat(0.5f, 480).ToArray(), 48_000);
        engine.SetMuted(id, true);

        var output = new float[240 * 2];
        engine.Read(output, 240);
        Assert.All(output, value => Assert.Equal(0f, value));
    }

    [Fact]
    public void RemovingSourceStopsStats()
    {
        var engine = new MixEngine();
        var id = engine.AddSource("a", 48_000);
        engine.Enqueue(id, new float[480], 48_000);
        Assert.True(engine.RemoveSource(id));
        Assert.Empty(engine.Snapshot().Sources);
        Assert.False(engine.RemoveSource(id));
    }

    private static float[] MakeSine(int frames, int sampleRate, float amplitude)
    {
        var result = new float[frames];
        for (var i = 0; i < frames; i++)
        {
            result[i] = amplitude * MathF.Sin(2 * MathF.PI * 440 * i / sampleRate);
        }
        return result;
    }
}
