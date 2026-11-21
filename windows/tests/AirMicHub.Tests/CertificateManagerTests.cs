using System.Security.Cryptography.X509Certificates;
using AirMicHub.Core;
using AirMicHub.Core.Certificates;
using Xunit;

namespace AirMicHub.Tests;

public class CertificateManagerTests
{
    [Fact]
    public void GeneratesCertificateCoveringLanAddressesAndLocalhost()
    {
        var directory = NewDirectory();
        try
        {
            var manager = new CertificateManager(Path.Combine(directory, "cert.pfx"));
            var certificate = manager.GetOrCreate(new[] { "192.168.1.33", "10.0.0.7" }, "TEST-PC");

            Assert.True(certificate.HasPrivateKey);
            Assert.True(certificate.NotAfter > DateTime.UtcNow.AddDays(300));
            Assert.True(CertificateManager.Covers(certificate, new[] { "192.168.1.33", "10.0.0.7" }, "TEST-PC"));

            var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().Single();
            var names = san.EnumerateDnsNames().ToList();
            var ips = san.EnumerateIPAddresses().Select(address => address.ToString()).ToList();
            Assert.Contains("localhost", names);
            Assert.Contains("192.168.1.33", ips);
            Assert.Contains("127.0.0.1", ips);
        }
        finally
        {
            TryDelete(directory);
        }
    }

    [Fact]
    public void ReusesPersistedCertificateAndRegeneratesOnAddressChange()
    {
        var directory = NewDirectory();
        try
        {
            var path = Path.Combine(directory, "cert.pfx");
            var first = new CertificateManager(path).GetOrCreate(new[] { "192.168.1.33" }, "TEST-PC");
            var second = new CertificateManager(path).GetOrCreate(new[] { "192.168.1.33" }, "TEST-PC");
            Assert.Equal(first.Thumbprint, second.Thumbprint);

            var third = new CertificateManager(path).GetOrCreate(new[] { "192.168.1.34" }, "TEST-PC");
            Assert.NotEqual(first.Thumbprint, third.Thumbprint);
            Assert.True(CertificateManager.Covers(third, new[] { "192.168.1.34" }, "TEST-PC"));
        }
        finally
        {
            TryDelete(directory);
        }
    }

    [Fact]
    public void ResetRemovesStoredCertificate()
    {
        var directory = NewDirectory();
        try
        {
            var path = Path.Combine(directory, "cert.pfx");
            var manager = new CertificateManager(path);
            manager.GetOrCreate(Array.Empty<string>(), "TEST-PC");
            Assert.True(File.Exists(path));
            manager.Reset();
            Assert.False(File.Exists(path));
        }
        finally
        {
            TryDelete(directory);
        }
    }

    private static string NewDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "airmic-cert-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static void TryDelete(string path)
    {
        try { Directory.Delete(path, recursive: true); } catch { }
    }
}
