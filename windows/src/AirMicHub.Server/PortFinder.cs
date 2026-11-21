using System.Net;
using System.Net.Sockets;

namespace AirMicHub.Server;

/// <summary>Finds bindable TCP ports for the automatic fallback when 8765/8787 are taken.</summary>
public static class PortFinder
{
    public static bool IsFree(int port)
    {
        try
        {
            var listener = new TcpListener(IPAddress.Any, port);
            listener.Start();
            listener.Stop();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static (int MicPort, int SpeakerPort)? FindPair(int micStart, int speakerStart, int span = 40)
    {
        for (var mic = micStart; mic < micStart + span && mic <= 65535; mic++)
        {
            if (!IsFree(mic)) continue;
            for (var speaker = speakerStart; speaker < speakerStart + span && speaker <= 65535; speaker++)
            {
                if (speaker == mic) continue;
                if (!IsFree(speaker)) continue;
                return (mic, speaker);
            }
        }
        return null;
    }
}
