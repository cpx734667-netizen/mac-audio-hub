using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace AirMicHub.Core;

public sealed record LanAddress(string Address, string InterfaceName, string Kind, int Score);

/// <summary>
/// Picks the LAN IPv4 address phones should use. VPN/virtual adapters are kept in the
/// list (some users really do need them) but ranked below Wi-Fi and Ethernet.
/// </summary>
public static class NetworkInfo
{
    public static IReadOnlyList<LanAddress> GetLanAddresses()
    {
        var results = new List<LanAddress>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;

                var props = nic.GetIPProperties();
                foreach (var unicast in props.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var text = unicast.Address.ToString();
                    if (text.StartsWith("127.", StringComparison.Ordinal)) continue;
                    if (text.StartsWith("169.254.", StringComparison.Ordinal)) continue;

                    var kind = KindOf(nic);
                    results.Add(new LanAddress(text, nic.Name, kind, ScoreOf(kind, nic)));
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"枚举网卡失败：{ex.Message}");
        }

        return results
            .GroupBy(item => item.Address)
            .Select(group => group.OrderByDescending(item => item.Score).First())
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Address, StringComparer.Ordinal)
            .ToList();
    }

    public static string? GetPrimaryAddress(string? preferred = null)
    {
        var addresses = GetLanAddresses();
        if (addresses.Count == 0) return null;
        if (!string.IsNullOrWhiteSpace(preferred))
        {
            var match = addresses.FirstOrDefault(item =>
                string.Equals(item.Address, preferred, StringComparison.OrdinalIgnoreCase));
            if (match is not null) return match.Address;
        }
        return addresses[0].Address;
    }

    public static IReadOnlyList<string> GetLanIpv4Addresses() =>
        GetLanAddresses().Select(item => item.Address).ToList();

    public static bool IsLanAddress(string? address) =>
        !string.IsNullOrWhiteSpace(address) && IPAddress.TryParse(address, out var ip) &&
        ip.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ip);

    private static string KindOf(NetworkInterface nic)
    {
        var text = (nic.Name + " " + nic.Description).ToLowerInvariant();
        if (text.Contains("vpn") || text.Contains("tap") || text.Contains("tun") ||
            text.Contains("wireguard") || text.Contains("tailscale") || text.Contains("zerotier") ||
            text.Contains("wintun") || text.Contains("radmin"))
            return "VPN";
        if (text.Contains("vethernet") || text.Contains("hyper-v") || text.Contains("virtualbox") ||
            text.Contains("vmware") || text.Contains("wsl") || text.Contains("virtual"))
            return "虚拟网卡";
        if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ||
            text.Contains("wi-fi") || text.Contains("wifi") || text.Contains("wlan") || text.Contains("无线"))
            return "Wi-Fi";
        if (nic.NetworkInterfaceType == NetworkInterfaceType.Ethernet ||
            nic.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet)
            return "以太网";
        return "其他";
    }

    private static int ScoreOf(string kind, NetworkInterface nic)
    {
        var score = kind switch
        {
            "以太网" => 100,
            "Wi-Fi" => 95,
            "其他" => 60,
            "虚拟网卡" => 25,
            "VPN" => 15,
            _ => 10,
        };

        try
        {
            // Prefer the adapter Windows actually routes through.
            if (nic.GetIPProperties().GatewayAddresses.Any(gateway =>
                    gateway.Address is not null && !gateway.Address.Equals(IPAddress.Any)))
            {
                score += 40;
            }
        }
        catch
        {
            // ignore adapters that refuse to report gateways
        }

        if (nic.Speed > 100_000_000) score += 2;
        return score;
    }
}
