using System.Buffers.Binary;

namespace AirMicHub.Core.Audio;

/// <summary>PCM byte/sample helpers used by both the phone mic path and the 8787 player.</summary>
public static class Pcm
{
    public static void Int16ToFloat(ReadOnlySpan<byte> source, Span<float> destination)
    {
        var count = Math.Min(source.Length / 2, destination.Length);
        for (var i = 0; i < count; i++)
        {
            destination[i] = BinaryPrimitives.ReadInt16LittleEndian(source.Slice(i * 2, 2)) / 32768f;
        }
    }

    public static float[] Int16ToFloat(ReadOnlySpan<byte> source)
    {
        var samples = new float[source.Length / 2];
        Int16ToFloat(source, samples);
        return samples;
    }

    public static void FloatToInt16(ReadOnlySpan<float> source, Span<byte> destination)
    {
        var count = Math.Min(source.Length, destination.Length / 2);
        for (var i = 0; i < count; i++)
        {
            var value = Math.Clamp(source[i], -1f, 1f);
            var scaled = value < 0 ? value * 0x8000 : value * 0x7fff;
            BinaryPrimitives.WriteInt16LittleEndian(destination.Slice(i * 2, 2), (short)Math.Round(scaled));
        }
    }

    public static byte[] FloatToInt16(ReadOnlySpan<float> source)
    {
        var bytes = new byte[source.Length * 2];
        FloatToInt16(source, bytes);
        return bytes;
    }

    public static float[] BytesToFloat(ReadOnlySpan<byte> source)
    {
        var samples = new float[source.Length / 4];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = BinaryPrimitives.ReadSingleLittleEndian(source.Slice(i * 4, 4));
        }
        return samples;
    }

    public static byte[] FloatToBytes(ReadOnlySpan<float> source)
    {
        var bytes = new byte[source.Length * 4];
        for (var i = 0; i < source.Length; i++)
        {
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(i * 4, 4), source[i]);
        }
        return bytes;
    }

    /// <summary>Downmixes interleaved frames to mono by averaging channels.</summary>
    public static float[] DownmixToMono(ReadOnlySpan<float> interleaved, int channels)
    {
        if (channels <= 1) return interleaved.ToArray();
        var frames = interleaved.Length / channels;
        var mono = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++)
            {
                sum += interleaved[frame * channels + channel];
            }
            mono[frame] = sum / channels;
        }
        return mono;
    }

    /// <summary>
    /// Converts an arbitrary WASAPI capture buffer to mono Float32 at its native sample rate.
    /// Supports IEEE float 32, PCM 16/24/32. Unknown formats return an empty array.
    /// </summary>
    public static float[] DecodeToMonoFloat(ReadOnlySpan<byte> data, int bitsPerSample, bool isFloat, int channels)
    {
        if (channels <= 0) return Array.Empty<float>();
        float[] interleaved;
        if (isFloat && bitsPerSample == 32)
        {
            interleaved = BytesToFloat(data);
        }
        else if (!isFloat && bitsPerSample == 16)
        {
            interleaved = new float[data.Length / 2];
            for (var i = 0; i < interleaved.Length; i++)
            {
                interleaved[i] = BinaryPrimitives.ReadInt16LittleEndian(data.Slice(i * 2, 2)) / 32768f;
            }
        }
        else if (!isFloat && bitsPerSample == 32)
        {
            interleaved = new float[data.Length / 4];
            for (var i = 0; i < interleaved.Length; i++)
            {
                interleaved[i] = BinaryPrimitives.ReadInt32LittleEndian(data.Slice(i * 4, 4)) / 2147483648f;
            }
        }
        else if (!isFloat && bitsPerSample == 24)
        {
            var sampleCount = data.Length / 3;
            interleaved = new float[sampleCount];
            for (var i = 0; i < sampleCount; i++)
            {
                var offset = i * 3;
                var value = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
                if ((value & 0x800000) != 0) value |= unchecked((int)0xFF000000);
                interleaved[i] = value / 8388608f;
            }
        }
        else
        {
            return Array.Empty<float>();
        }

        return DownmixToMono(interleaved, channels);
    }

    /// <summary>
    /// Decodes an arbitrary WASAPI buffer to interleaved Float32 without downmixing.
    /// Unknown formats return an empty array.
    /// </summary>
    public static float[] DecodeInterleavedFloat(ReadOnlySpan<byte> data, int bitsPerSample, bool isFloat)
    {
        if (isFloat && bitsPerSample == 32) return BytesToFloat(data);

        if (!isFloat && bitsPerSample == 16)
        {
            var samples = new float[data.Length / 2];
            for (var i = 0; i < samples.Length; i++)
            {
                samples[i] = BinaryPrimitives.ReadInt16LittleEndian(data.Slice(i * 2, 2)) / 32768f;
            }
            return samples;
        }

        if (!isFloat && bitsPerSample == 32)
        {
            var samples = new float[data.Length / 4];
            for (var i = 0; i < samples.Length; i++)
            {
                samples[i] = BinaryPrimitives.ReadInt32LittleEndian(data.Slice(i * 4, 4)) / 2147483648f;
            }
            return samples;
        }

        if (!isFloat && bitsPerSample == 24)
        {
            var sampleCount = data.Length / 3;
            var samples = new float[sampleCount];
            for (var i = 0; i < sampleCount; i++)
            {
                var offset = i * 3;
                var value = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
                if ((value & 0x800000) != 0) value |= unchecked((int)0xFF000000);
                samples[i] = value / 8388608f;
            }
            return samples;
        }

        return Array.Empty<float>();
    }

    public static float Peak(ReadOnlySpan<float> samples)
    {
        var peak = 0f;
        foreach (var sample in samples)
        {
            var abs = Math.Abs(sample);
            if (abs > peak) peak = abs;
        }
        return peak;
    }

    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return 0f;
        double sum = 0;
        foreach (var sample in samples)
        {
            sum += (double)sample * sample;
        }
        return (float)Math.Sqrt(sum / samples.Length);
    }
}
