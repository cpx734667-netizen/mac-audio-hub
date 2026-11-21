import Foundation
import Network
import CommonCrypto

// MARK: - WebSocket 帧解析

struct WSFrame {
    let fin: Bool
    let opcode: UInt8
    let payload: Data
}

/// 累积字节流，解析出完整的 WebSocket 帧
final class WSFrameParser {
    private var buffer = Data()

    func append(_ data: Data) -> [WSFrame] {
        buffer.append(data)
        var frames: [WSFrame] = []
        while let f = parseOne() { frames.append(f) }
        return frames
    }

    private func parseOne() -> WSFrame? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[0]
        let b1 = buffer[1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        var len = Int(b1 & 0x7F)
        var offset = 2
        if len == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            len = (Int(buffer[offset]) << 8) | Int(buffer[offset + 1])
            offset += 2
        } else if len == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(buffer[offset + i]) }
            len = Int(v)
            offset += 8
        }
        let masked = (b1 & 0x80) != 0
        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<(offset + 4)])
            offset += 4
        }
        guard buffer.count >= offset + len else { return nil }
        var payload = Data(buffer[offset..<(offset + len)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
        }
        buffer.removeSubrange(0..<(offset + len))
        return WSFrame(fin: fin, opcode: opcode, payload: payload)
    }
}

// MARK: - 服务端帧编码

func makeWSFrame(opcode: UInt8, payload: Data) -> Data {
    var out = Data()
    out.append(0x80 | opcode) // FIN
    let len = payload.count
    if len < 126 {
        out.append(UInt8(len))
    } else if len <= 0xFFFF {
        out.append(126)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
    } else {
        out.append(127)
        let big = UInt64(len)
        for i in stride(from: 7, through: 0, by: -1) {
            out.append(UInt8((big >> (i * 8)) & 0xFF))
        }
    }
    out.append(payload)
    return out
}

// MARK: - 客户端连接

/// 一个已连接的浏览器设备
final class SpeakerClient {
    let id: UUID
    var name: String
    let ip: String
    var deviceId: String?
    var isActive = false
    var lastActivity = Date()
    private let conn: NWConnection
    private var sending = false
    private let queue: DispatchQueue

    init(id: UUID, name: String, ip: String, conn: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.name = name
        self.ip = ip
        self.conn = conn
        self.queue = queue
    }

    /// 控制类消息：直接发送
    func send(_ payload: Data) {
        conn.send(content: payload, completion: .contentProcessed { _ in })
    }

    /// 音频帧：发送中时缓冲少量帧吸收抖动，超限丢最旧帧（保实时、防积压）
    /// 性能优化版：12 帧（240ms）容忍，网络瞬时拥塞几乎不丢帧 → 不跳音
    private var pendingFrames: [Data] = []
    private let maxPendingFrames = 12
    func sendAudio(_ payload: Data) {
        if sending {
            if pendingFrames.count < maxPendingFrames {
                pendingFrames.append(payload)
            } else {
                pendingFrames.removeFirst()
                pendingFrames.append(payload)
            }
            return
        }
        sending = true
        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.queue.async {
                guard let self = self else { return }
                self.sending = false
                if !self.pendingFrames.isEmpty {
                    let p = self.pendingFrames.removeFirst()
                    self.sendAudio(p)
                }
            }
        })
    }

    func close() {
        conn.cancel()
    }
}

// MARK: - 服务器

final class SpeakerServer {

    private let model: SpeakerModel
    private let queue = DispatchQueue(label: "com.macspeaker.server", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [UUID: SpeakerClient] = [:]
    private var clientSeq = 0
    private var heartbeatTimer: DispatchSourceTimer?

    init(model: SpeakerModel) {
        self.model = model
    }

    /// 任一设备请求开始播放
    var onClientRequestedStart: (() -> Void)?
    /// 任一设备请求停止播放
    var onClientRequestedStop: (() -> Void)?
    /// 设备列表变化
    var onDeviceListChanged: (() -> Void)?
    /// 监听失败
    var onServerFailed: ((String) -> Void)?

    var activeClientCount: Int { clients.values.filter { $0.isActive }.count }

    func start(port: UInt16) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.service = NWListener.Service(name: "Mac音箱", type: "_http._tcp", domain: nil)
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                self?.onServerFailed?(err.localizedDescription)
            case .cancelled:
                self?.listener = nil
            default:
                break
            }
        }
        l.start(queue: queue)
        listener = l
        startHeartbeat()
    }

    /// 每 20 秒向所有客户端发 WebSocket Ping，防止 iOS Safari 等浏览器
    /// 因连接空闲（约 60 秒无流量）而自动断开；同时清理超过 45 秒
    /// 无任何响应（含 pong）的僵尸连接，避免重连风暴
    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let staleIds = self.clients
                .filter { now.timeIntervalSince($0.value.lastActivity) > 45 }
                .map { $0.key }
            for id in staleIds {
                if let c = self.clients[id] {
                    print("[server] 心跳超时移除僵尸连接 \(c.name) (\(id))")
                    self.removeClient(c)
                }
            }
            let ping = makeWSFrame(opcode: 0x9, payload: Data("hb".utf8))
            for c in self.clients.values {
                c.send(ping)
            }
        }
        t.resume()
        heartbeatTimer = t
    }

    func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        listener?.cancel()
        listener = nil
        for c in clients.values { c.close() }
        clients.removeAll()
        syncModel()
    }

    /// Mac 端 UI 切换某设备是否推流
    func setDeviceActive(id: UUID, active: Bool) {
        queue.async { [weak self] in
            guard let self = self, let c = self.clients[id] else { return }
            c.isActive = active
            self.syncModel()
            if active {
                self.onClientRequestedStart?()
            } else {
                self.onClientRequestedStop?()
            }
        }
    }

    /// 广播音频帧给所有播放中的设备
    func broadcastAudio(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let payload = self.efficient ? Self.convertToInt16(data) : data
            let frame = makeWSFrame(opcode: 0x2, payload: payload)
            for c in self.clients.values where c.isActive {
                c.sendAudio(frame)
            }
        }
    }

    /// 高效传输模式：Float32 → Int16（带宽减半，音质几乎无损）
    private var efficient = false
    func setEfficientMode(_ on: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.efficient = on
            let state = jsonData(["type": "state", "format": on ? "int16le" : "float32le"])
            for c in self.clients.values {
                c.send(makeWSFrame(opcode: 0x1, payload: state))
            }
        }
    }

    private static func convertToInt16(_ data: Data) -> Data {
        let count = data.count / 4
        guard count > 0 else { return data }
        var out = Data(count: count * 2)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let i16 = dst.bindMemory(to: Int16.self)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<count {
                    let f = floats[i]
                    if f >= 1.0 { i16[i] = Int16.max }
                    else if f <= -1.0 { i16[i] = Int16.min }
                    else { i16[i] = Int16(f * 32767.0) }
                }
            }
        }
        return out
    }

    /// 广播 JSON 控制消息给所有设备
    func broadcastControl(_ payload: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let frame = makeWSFrame(opcode: 0x1, payload: payload)
            for c in self.clients.values {
                c.send(frame)
            }
        }
    }

    // MARK: - 连接处理

    private func handleConnection(_ conn: NWConnection) {
        let id = UUID()
        let ip = endpointIP(conn.endpoint)
        clientSeq += 1
        let client = SpeakerClient(id: id, name: "设备 \(clientSeq)", ip: ip, conn: conn, queue: queue)
        conn.start(queue: queue)
        clients[id] = client
        syncModel()
        print("[server] 新连接 id=\(id.uuidString.prefix(8)) ip=\(ip)")

        var httpBuffer = Data()
        var wsParser: WSFrameParser?
        var upgraded = false

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    if upgraded, let parser = wsParser {
                        for frame in parser.append(data) {
                            self.handleFrame(frame, client: client)
                        }
                    } else {
                        httpBuffer.append(data)
                        if let headerEnd = httpBuffer.range(of: Data("\r\n\r\n".utf8)) {
                            let headData = httpBuffer.subdata(in: httpBuffer.startIndex..<headerEnd.lowerBound)
                            httpBuffer.removeSubrange(httpBuffer.startIndex..<headerEnd.upperBound)
                            upgraded = self.handleHTTP(headData, conn: conn, client: client)
                            if upgraded {
                                wsParser = WSFrameParser()
                                for frame in wsParser!.append(httpBuffer) {
                                    self.handleFrame(frame, client: client)
                                }
                                httpBuffer.removeAll()
                            }
                        }
                    }
                }
                if isComplete || error != nil {
                    if error != nil { print("[server] 连接错误/关闭 \(client.name): \(String(describing: error))") }
                    self.removeClient(client)
                    return
                }
                receive()
            }
        }
        receive()
    }

    /// 处理 HTTP 请求头，返回是否升级为 WebSocket
    private func handleHTTP(_ head: Data, conn: NWConnection, client: SpeakerClient) -> Bool {
        guard let headStr = String(data: head, encoding: .utf8) else {
            respondText(conn: conn, status: 400, text: "Bad Request")
            return false
        }
        let lines = headStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            if let idx = line.firstIndex(of: ":") {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        if method == "GET", path == "/ws", headers["upgrade"]?.lowercased() == "websocket" {
            guard let key = headers["sec-websocket-key"] else {
                respondText(conn: conn, status: 400, text: "Bad Request")
                return false
            }
            let accept = websocketAccept(key: key)
            let resp = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] _ in
                print("[server] WS 升级响应已发送，准备 sendReady")
                self?.sendReady(client)
            })
            return true
        }

        if method == "GET", path == "/" {
            respondHTML(conn: conn, html: WebAssets.indexHTML)
            return false
        }

        if method == "GET", path == "/health" {
            let payload = jsonData([
                "status": "ok",
                "app": "MacSpeaker",
                "port": Int(model.port),
                "devices": clients.count,
                "active": activeClientCount,
                "efficient": efficient,
                "captureEnabled": model.captureEnabled,
                "capturing": model.isCapturing,
                "permission": model.hasScreenPermission.map { $0 ? "granted" : "denied" } ?? "unknown",
                "captureError": model.captureError ?? ""
            ])
            respondJSON(conn: conn, data: payload)
            return false
        }

        respondText(conn: conn, status: 404, text: "Not Found")
        return false
    }

    private func sendReady(_ client: SpeakerClient) {
        let msg: [String: Any] = [
            "type": "ready",
            "sampleRate": AudioEngine.sampleRate,
            "channels": AudioEngine.channels,
            "format": efficient ? "int16le" : "float32le",
            "deviceId": client.id.uuidString
        ]
        let frame = makeWSFrame(opcode: 0x1, payload: jsonData(msg))
        client.send(frame)
        print("[server] sendReady -> \(client.name), frame=\(frame.count)B")
    }

    private func handleFrame(_ frame: WSFrame, client: SpeakerClient) {
        client.lastActivity = Date()
        switch frame.opcode {
        case 0x8: // close
            removeClient(client)
        case 0x9: // ping
            client.send(makeWSFrame(opcode: 0xA, payload: frame.payload))
        case 0x1, 0x2:
            handleMessage(frame.payload, client: client)
        default:
            break
        }
    }

    private func handleMessage(_ payload: Data, client: SpeakerClient) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else { return }
        print("[server] 消息 from \(client.name): \(type)")

        switch type {
        case "start":
            client.isActive = true
            syncModel()
            onClientRequestedStart?()
        case "stop":
            client.isActive = false
            syncModel()
            onClientRequestedStop?()
        case "device":
            if let id = obj["id"] as? String, !id.isEmpty {
                client.deviceId = id
                if let name = obj["name"] as? String, !name.isEmpty {
                    client.name = String(name.prefix(40))
                }
                // 同一设备（按浏览器生成的唯一 ID）重复连接：踢旧接新，防止双声音；
                // 不同设备即使 IP 相同也互不影响，支持任意多台设备并发
                let sameIds = clients.values.filter { $0.deviceId == id && $0.id != client.id }
                for old in sameIds {
                    print("[server] 同设备 \(id) 重复连接，踢旧 \(old.id)")
                    removeClient(old)
                }
                syncModel()
            }
        case "ping":
            let pong = jsonData(["type": "pong", "t": Date().timeIntervalSince1970])
            client.send(makeWSFrame(opcode: 0x1, payload: pong))
        case "name":
            if let name = obj["name"] as? String, !name.isEmpty {
                client.name = String(name.prefix(40))
                syncModel()
            }
        default:
            break
        }
    }

    // MARK: - 工具

    private func removeClient(_ client: SpeakerClient) {
        guard clients[client.id] != nil else { return }
        let wasActive = client.isActive
        clients.removeValue(forKey: client.id)
        client.close()
        syncModel()
        if wasActive {
            onClientRequestedStop?()
        }
    }

    private func syncModel() {
        let snapshot = clients.values.map { (id: $0.id, name: $0.name, ip: $0.ip, active: $0.isActive) }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let existing = Dictionary(uniqueKeysWithValues: self.model.devices.map { ($0.id, $0.connectedAt) })
            var newList: [SpeakerDevice] = []
            for s in snapshot {
                let connAt = existing[s.id] ?? Date()
                newList.append(SpeakerDevice(id: s.id, name: s.name, ip: s.ip, connectedAt: connAt, isActive: s.active))
            }
            self.model.devices = newList
            self.onDeviceListChanged?()
        }
    }

    private func endpointIP(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return "\(addr)"
            case .ipv6(let addr): return "\(addr)"
            case .name(let name, _): return name
            default: break
            }
        }
        return "未知"
    }

    private func respondHTML(conn: NWConnection, html: String) {
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: text/html; charset=utf-8\r\n" +
                     "Content-Length: \(body.count)\r\n" +
                     "Cache-Control: no-cache\r\n" +
                     "Connection: close\r\n\r\n"
        conn.send(content: header.data(using: .utf8)! + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respondJSON(conn: NWConnection, data: Data) {
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: application/json; charset=utf-8\r\n" +
                     "Content-Length: \(data.count)\r\n" +
                     "Cache-Control: no-store\r\n" +
                     "Connection: close\r\n\r\n"
        conn.send(content: header.data(using: .utf8)! + data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respondText(conn: NWConnection, status: Int, text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status) \(statusText(status))\r\n" +
                     "Content-Type: text/plain; charset=utf-8\r\n" +
                     "Content-Length: \(body.count)\r\n" +
                     "Connection: close\r\n\r\n"
        conn.send(content: header.data(using: .utf8)! + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func statusText(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return ""
        }
    }
}

// MARK: - 全局函数

func websocketAccept(key: String) -> String {
    let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let combined = key + guid
    let digest = combined.withCString { str -> [UInt8] in
        var d = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(str, CC_LONG(strlen(str)), &d)
        return d
    }
    return Data(digest).base64EncodedString()
}

func jsonData(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}
