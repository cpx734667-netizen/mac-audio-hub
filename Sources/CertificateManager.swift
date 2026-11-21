import Foundation
import Security

enum CertificateError: LocalizedError {
    case opensslMissing
    case commandFailed(String)
    case importFailed(OSStatus)
    case noIdentity

    var errorDescription: String? {
        switch self {
        case .opensslMissing:
            return "找不到系统自带的 openssl，无法创建本地安全证书。"
        case .commandFailed(let message):
            return "创建本地证书失败：\(message)"
        case .importFailed(let status):
            return "导入本地证书失败（OSStatus \(status)）。"
        case .noIdentity:
            return "本地证书中没有可用的身份。"
        }
    }
}

/// Creates a self-signed, Apple-compatible TLS server certificate for the
/// current LAN address. No certificate authority or account is required.
final class CertificateManager {
    private let fileManager = FileManager.default
    private let directory: URL
    private let password = "airmic-local-tls"

    init() throws {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directory = support.appendingPathComponent("AirMic", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private var keyURL: URL { directory.appendingPathComponent("server.key") }
    private var certURL: URL { directory.appendingPathComponent("server.crt") }
    private var p12URL: URL { directory.appendingPathComponent("server.p12") }
    private var metadataURL: URL { directory.appendingPathComponent("certificate.json") }

    struct Metadata: Codable {
        let ips: [String]
        let createdAt: Date
    }

    func loadOrCreateIdentity(for address: NetworkAddress) throws -> SecIdentity {
        let now = Date()
        if let metadata = readMetadata(),
           metadata.ips.contains(address.ip),
           now.timeIntervalSince(metadata.createdAt) < 60 * 60 * 24 * 700,
           fileManager.fileExists(atPath: keyURL.path),
           fileManager.fileExists(atPath: certURL.path),
           fileManager.fileExists(atPath: p12URL.path) {
            do {
                return try importIdentity()
            } catch {
                // Fall through and regenerate a clean identity.
            }
        }

        try generate(for: address)
        let metadata = Metadata(ips: certificateIPs(main: address.ip), createdAt: now)
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL, options: .atomic)
        }
        return try importIdentity()
    }

    private func certificateIPs(main: String) -> [String] {
        var ips = ["127.0.0.1", main]
        if let second = NetworkInfo.primaryIPv4()?.ip, !ips.contains(second) {
            ips.append(second)
        }
        return Array(Set(ips)).sorted()
    }

    private func readMetadata() -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func generate(for address: NetworkAddress) throws {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/openssl") else {
            throw CertificateError.opensslMissing
        }

        let configURL = directory.appendingPathComponent("openssl.cnf")
        let host = NetworkInfo.localHostName()
        var altNames: [String] = [
            "DNS.1 = localhost",
            "DNS.2 = \(sanitizeDNS(host))",
            "IP.1 = 127.0.0.1"
        ]
        var ipIndex = 2
        for ip in certificateIPs(main: address.ip) where ip != "127.0.0.1" {
            altNames.append("IP.\(ipIndex) = \(ip)")
            ipIndex += 1
        }

        let config = """
        [req]
        default_bits = 2048
        prompt = no
        default_md = sha256
        distinguished_name = dn
        x509_extensions = v3_req

        [dn]
        CN = AirMic Local Microphone
        O = AirMic
        OU = Local Network

        [v3_req]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @alt_names

        [alt_names]
        \(altNames.joined(separator: "\n"))
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-days", "825",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-config", configURL.path,
            "-extensions", "v3_req"
        ])

        try runOpenSSL([
            "pkcs12", "-export",
            "-out", p12URL.path,
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-passout", "pass:\(password)"
        ])

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certURL.path)
    }

    private func sanitizeDNS(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let result = String(value.unicodeScalars.filter { allowed.contains($0) })
        return result.isEmpty ? "airmic.local" : result
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CertificateError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let message = (String(data: errorData, encoding: .utf8)
                ?? String(data: outputData, encoding: .utf8)
                ?? "openssl 退出码 \(process.terminationStatus)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CertificateError.commandFailed(message)
        }
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
    }

    private func importIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: p12URL)
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        // Importing into the login keychain would make every TLS handshake ask
        // the user to authorize access to the private key. Keep this short-lived
        // local certificate's key in process memory instead.
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw CertificateError.importFailed(status)
        }
        guard let items = rawItems as? [[String: Any]],
              let first = items.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw CertificateError.noIdentity
        }
        return value as! SecIdentity
    }
}
