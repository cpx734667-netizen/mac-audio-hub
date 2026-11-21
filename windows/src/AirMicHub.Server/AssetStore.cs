using System.Reflection;
using AirMicHub.Core;

namespace AirMicHub.Server;

/// <summary>
/// Web resources are embedded in the assembly so a single-file publish still serves the
/// phone pages. A loose copy under web\ is also deployed for debugging and takes over only
/// when the embedded resource is missing.
/// </summary>
public static class AssetStore
{
    private const string ResourcePrefix = "AirMicHub.Server.Assets.";

    public static byte[] PhoneHtml { get; } = Load("phone.html", "<!doctype html><meta charset=\"utf-8\"><h1>AirMic</h1><p>资源缺失</p>");
    public static byte[] SpeakerHtml { get; } = Load("speaker.html", "<!doctype html><meta charset=\"utf-8\"><h1>AirMic</h1><p>资源缺失</p>");
    public static byte[] Worklet { get; } = Load("pcm-worklet.js", "registerProcessor('pcm-processor', class extends AudioWorkletProcessor { process() { return true } })");
    public static byte[] Manifest { get; } = Load("manifest.webmanifest", "{\"name\":\"AirMic 手机麦克风\",\"short_name\":\"AirMic\",\"start_url\":\"/\",\"display\":\"standalone\",\"background_color\":\"#080D1A\",\"theme_color\":\"#080D1A\"}");
    public static byte[] Favicon { get; } = Load("favicon.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" rx=\"16\" fill=\"#0B1220\"/></svg>");

    private static byte[] Load(string name, string fallback)
    {
        try
        {
            var assembly = typeof(AssetStore).Assembly;
            var resource = assembly.GetManifestResourceNames()
                .FirstOrDefault(candidate => candidate.EndsWith($".Assets.{name}", StringComparison.OrdinalIgnoreCase));
            if (resource is not null)
            {
                using var stream = assembly.GetManifestResourceStream(resource);
                if (stream is not null)
                {
                    using var memory = new MemoryStream();
                    stream.CopyTo(memory);
                    return memory.ToArray();
                }
            }

            foreach (var folder in new[] { "web", "Assets" })
            {
                var loose = Path.Combine(AppContext.BaseDirectory, folder, name);
                if (File.Exists(loose)) return File.ReadAllBytes(loose);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"加载 web 资源 {name} 失败：{ex.Message}");
        }

        return System.Text.Encoding.UTF8.GetBytes(fallback);
    }
}
