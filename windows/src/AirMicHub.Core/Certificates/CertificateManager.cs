using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace AirMicHub.Core.Certificates;

/// <summary>
/// Creates and caches the self-signed TLS certificate used by the 8765 phone page.
///
/// Phones only accept the certificate when the SAN list contains the exact IP in the
/// address bar, so the certificate is rebuilt whenever the LAN IPv4 set changes. The PFX
/// is encrypted at rest with DPAPI (current user) in
/// %LOCALAPPDATA%\AirMicHub\cert.pfx. No attempt is made to install the certificate into
/// the Windows trust store; users continue past the browser warning on the phone.
/// </summary>
public sealed class CertificateManager
{
    private const string PfxPassword = "AirMicHub-Local-Certificate";
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("AirMicHub.Certificate.v1");
    private readonly string _pfxPath;
    private readonly object _gate = new();
    private X509Certificate2? _cached;

    public CertificateManager(string? pfxPath = null)
    {
        _pfxPath = pfxPath ?? AppPaths.CertificatePath;
    }

    public string CertificatePath => _pfxPath;

    public X509Certificate2 GetOrCreate(IReadOnlyCollection<string> lanAddresses, string hostName)
    {
        lock (_gate)
        {
            if (_cached is not null && Covers(_cached, lanAddresses, hostName))
            {
                return _cached;
            }

            var loaded = TryLoad();
            if (loaded is not null && Covers(loaded, lanAddresses, hostName))
            {
                var previous = _cached;
                _cached = loaded;
                previous?.Dispose();
                return loaded;
            }

            if (loaded is not null)
            {
                loaded.Dispose();
            }

            Log.Info(_cached is null
                ? "未找到可用证书，正在生成自签名证书。"
                : "局域网地址变化，正在重新生成自签名证书。");

            var generated = Generate(lanAddresses, hostName);
            var old = _cached;
            _cached = generated;
            old?.Dispose();
            return generated;
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _cached?.Dispose();
            _cached = null;
            try
            {
                if (File.Exists(_pfxPath)) File.Delete(_pfxPath);
                Log.Info("已删除本地证书，下次启动会重新生成。");
            }
            catch (Exception ex)
            {
                Log.Warn($"删除证书失败：{ex.Message}");
            }
        }
    }

    public static bool Covers(X509Certificate2 certificate, IReadOnlyCollection<string> lanAddresses, string hostName)
    {
        if (!certificate.HasPrivateKey) return false;
        if (certificate.NotAfter.ToUniversalTime() < DateTime.UtcNow.AddDays(7)) return false;

        var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().FirstOrDefault();
        if (san is null) return false;

        var dnsNames = san.EnumerateDnsNames().Select(name => name.Trim().ToLowerInvariant()).ToHashSet();
        var ips = san.EnumerateIPAddresses().Select(address => address.ToString()).ToHashSet();

        if (!dnsNames.Contains("localhost")) return false;
        if (!string.IsNullOrWhiteSpace(hostName) &&
            !dnsNames.Contains(hostName.Trim().ToLowerInvariant()) &&
            !ips.Contains(hostName.Trim()))
        {
            // Host name is a nicety, not a requirement; LAN IPs matter for phones.
        }

        foreach (var address in lanAddresses)
        {
            if (!IPAddress.TryParse(address, out var ip)) continue;
            if (IPAddress.IsLoopback(ip)) continue;
            if (!ips.Contains(ip.ToString())) return false;
        }

        return true;
    }

    private X509Certificate2? TryLoad()
    {
        try
        {
            if (!File.Exists(_pfxPath)) return null;
            var protectedBytes = File.ReadAllBytes(_pfxPath);
            var pfx = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            var certificate = new X509Certificate2(
                pfx,
                PfxPassword,
                X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
            Log.Info($"已加载本地证书：{certificate.Subject}，有效期至 {certificate.NotAfter:yyyy-MM-dd}");
            return certificate;
        }
        catch (Exception ex)
        {
            Log.Warn($"加载本地证书失败，将重新生成：{ex.Message}");
            return null;
        }
    }

    private X509Certificate2 Generate(IReadOnlyCollection<string> lanAddresses, string hostName)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            "CN=AirMic Hub",
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);

        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false)); // serverAuth

        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName("localhost");
        if (!string.IsNullOrWhiteSpace(hostName))
        {
            san.AddDnsName(hostName.Trim());
        }
        san.AddIpAddress(IPAddress.Loopback);
        san.AddIpAddress(IPAddress.IPv6Loopback);
        foreach (var address in lanAddresses.Distinct())
        {
            if (IPAddress.TryParse(address, out var ip)) san.AddIpAddress(ip);
        }
        request.CertificateExtensions.Add(san.Build());
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));

        using var certificate = request.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddDays(-1),
            DateTimeOffset.UtcNow.AddYears(1));

        var pfx = certificate.Export(X509ContentType.Pfx, PfxPassword);
        SaveProtected(pfx, lanAddresses);

        var imported = new X509Certificate2(
            pfx,
            PfxPassword,
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
        Log.Info($"已生成自签名证书，覆盖：{string.Join(", ", lanAddresses)}");
        return imported;
    }

    private void SaveProtected(byte[] pfx, IReadOnlyCollection<string> lanAddresses)
    {
        try
        {
            var directory = Path.GetDirectoryName(_pfxPath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

            var protectedBytes = ProtectedData.Protect(pfx, Entropy, DataProtectionScope.CurrentUser);
            var temporary = _pfxPath + ".tmp";
            File.WriteAllBytes(temporary, protectedBytes);
            File.Move(temporary, _pfxPath, overwrite: true);
        }
        catch (Exception ex)
        {
            // The certificate still works for this session; only persistence failed.
            Log.Warn($"保存证书失败（本次运行不受影响）：{ex.Message}");
        }
    }
}
