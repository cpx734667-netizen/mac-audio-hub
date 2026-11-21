namespace AirMicHub.Core.Audio;

/// <summary>
/// Streaming Catmull-Rom resampler for interleaved Float32 audio. State is kept between
/// calls so 5 ms microphone frames are resampled without seams. Catmull-Rom keeps more
/// high-frequency detail than linear interpolation at a negligible CPU cost.
/// </summary>
public sealed class StreamingResampler
{
    private readonly int _channels;
    private readonly double _ratio; // input frames per output frame
    private float[] _buffer;
    private int _frameCount;
    private double _position;

    public StreamingResampler(int inputRate, int outputRate, int channels = 1)
    {
        if (inputRate <= 0) throw new ArgumentOutOfRangeException(nameof(inputRate));
        if (outputRate <= 0) throw new ArgumentOutOfRangeException(nameof(outputRate));
        _channels = Math.Max(1, channels);
        _ratio = (double)inputRate / outputRate;
        _buffer = new float[Math.Max(64, _channels * 32)];
        _frameCount = 0;
        _position = 0;
    }

    public double Ratio => _ratio;
    public int Channels => _channels;

    public void Reset()
    {
        _frameCount = 0;
        _position = 0;
    }

    /// <summary>
    /// Feeds <paramref name="inputFrames"/> frames and writes up to
    /// <paramref name="outputFrameCapacity"/> resampled frames. Returns the frame count written.
    /// </summary>
    public int Process(ReadOnlySpan<float> input, int inputFrames, Span<float> output, int outputFrameCapacity)
    {
        if (inputFrames < 0) inputFrames = 0;
        var samples = inputFrames * _channels;
        if (samples > input.Length) samples = input.Length;
        inputFrames = samples / _channels;

        EnsureCapacity(_frameCount + inputFrames);
        input[..samples].CopyTo(_buffer.AsSpan(_frameCount * _channels));
        _frameCount += inputFrames;

        var written = 0;
        // Need one frame of history on the left and two frames on the right.
        while (written < outputFrameCapacity && _position + 2 < _frameCount)
        {
            var index = (int)_position;
            var fraction = _position - index;
            var p0 = Math.Max(0, index - 1) * _channels;
            var p1 = index * _channels;
            var p2 = Math.Min(_frameCount - 1, index + 1) * _channels;
            var p3 = Math.Min(_frameCount - 1, index + 2) * _channels;

            for (var channel = 0; channel < _channels; channel++)
            {
                var y0 = _buffer[p0 + channel];
                var y1 = _buffer[p1 + channel];
                var y2 = _buffer[p2 + channel];
                var y3 = _buffer[p3 + channel];
                var a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3;
                var b = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3;
                var c = -0.5 * y0 + 0.5 * y2;
                output[written * _channels + channel] = (float)(((a * fraction + b) * fraction + c) * fraction + y1);
            }

            _position += _ratio;
            written++;
        }

        Compact();
        return written;
    }

    private void Compact()
    {
        var dropFrames = (int)Math.Floor(_position) - 1;
        if (dropFrames <= 0) return;
        dropFrames = Math.Min(dropFrames, _frameCount);
        var remaining = _frameCount - dropFrames;
        if (remaining > 0)
        {
            Buffer.BlockCopy(
                _buffer,
                dropFrames * _channels * sizeof(float),
                _buffer,
                0,
                remaining * _channels * sizeof(float));
        }
        _frameCount = remaining;
        _position -= dropFrames;
    }

    private void EnsureCapacity(int framesNeeded)
    {
        var required = framesNeeded * _channels + _channels * 4;
        if (_buffer.Length >= required) return;
        var size = _buffer.Length;
        while (size < required) size *= 2;
        Array.Resize(ref _buffer, size);
    }

    /// <summary>One-shot helper for tests and short buffers.</summary>
    public static float[] Resample(float[] interleaved, int inputRate, int outputRate, int channels)
    {
        if (inputRate == outputRate) return interleaved.ToArray();
        var frames = interleaved.Length / channels;
        var resampler = new StreamingResampler(inputRate, outputRate, channels);
        var capacity = (int)Math.Ceiling(frames * (double)outputRate / inputRate) + 8;
        var output = new float[capacity * channels];
        var written = resampler.Process(interleaved, frames, output, capacity);
        return output.AsSpan(0, written * channels).ToArray();
    }
}
