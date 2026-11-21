using NAudio.Wave;

namespace AirMicHub.Audio;

/// <summary>
/// WASAPI shared-mode endpoints almost always report WAVEFORMATEXTENSIBLE, whose Encoding is
/// "Extensible" rather than IeeeFloat/Pcm. The real encoding lives in the SubFormat GUID.
/// </summary>
public static class WaveFormatInfo
{
    private static readonly Guid IeeeFloatSubFormat = new("00000003-0000-0010-8000-00AA00389B71");
    private static readonly Guid PcmSubFormat = new("00000001-0000-0010-8000-00AA00389B71");

    public static bool IsFloat(WaveFormat format)
    {
        if (format.Encoding == WaveFormatEncoding.IeeeFloat) return true;
        return format.Encoding == WaveFormatEncoding.Extensible &&
               format is WaveFormatExtensible extensible &&
               extensible.SubFormat == IeeeFloatSubFormat;
    }

    public static bool IsPcm(WaveFormat format)
    {
        if (format.Encoding == WaveFormatEncoding.Pcm) return true;
        return format.Encoding == WaveFormatEncoding.Extensible &&
               format is WaveFormatExtensible extensible &&
               extensible.SubFormat == PcmSubFormat;
    }

    public static string Describe(WaveFormat format)
    {
        var kind = IsFloat(format) ? "float" : IsPcm(format) ? "pcm" : format.Encoding.ToString();
        return $"{format.SampleRate} Hz / {format.Channels} ch / {format.BitsPerSample} bit / {kind}";
    }
}
