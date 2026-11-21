import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct NetworkAddress: Equatable {
    let ip: String
    let interface: String
}

enum NetworkInfo {
    /// Returns the best IPv4 address for a phone on the same Wi-Fi/LAN.
    /// Ethernet (`en0`, `en1`, ...) is preferred; VPN and peer-to-peer
    /// interfaces are deliberately ignored.
    static func primaryIPv4() -> NetworkAddress? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(score: Int, address: NetworkAddress)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254."), ip != "0.0.0.0" else { continue }

            let score: Int
            switch name {
            case "en0": score = 100
            case "en1": score = 95
            default: score = name.hasPrefix("en") ? 70 : 50
            }
            candidates.append((score, NetworkAddress(ip: ip, interface: name)))
        }

        return candidates.sorted { $0.score > $1.score }.first?.address
    }

    static func localHostName() -> String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Finds an unused TCP port. There is still a tiny race before the
    /// listener binds, but in practice this avoids picking an occupied port.
    static func availablePort(startingAt first: UInt16, attempts: Int = 20) -> UInt16 {
        for offset in 0..<attempts {
            let port = first + UInt16(offset)
            if isPortAvailable(port) { return port }
        }
        return first
    }

    private static func isPortAvailable(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
