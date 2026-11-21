import Foundation
import Network
import Security

struct MicSourceDescriptor {
    let id: UUID
    let name: String
    let platform: String
    let channel: Int
    let sampleRate: Double
}

enum ServerEvent {
    case listening(port: UInt16)
    case pageOpened(userAgent: String)
    case pageClosed
    case sourceAdded(MicSourceDescriptor)
    case sourceRemoved(UUID)
    case stats(
        rttMilliseconds: Double,
        kbps: Double,
        queueMilliseconds: Double,
        outputLatencyMilliseconds: Double,
        level: Float,
        sampleRate: Double,
        sources: [MixSourceLevel],
        phoneCount: Int
    )
    case error(String)
}

/// A deliberately small HTTPS + WebSocket server. It exists only on the local
/// network, serves the phone microphone page, and receives PCM audio frames
/// from up to eight phones at the same time.
final class HTTPServer {
    let port: UInt16
    let audio: AudioMixer
    var onEvent: ((ServerEvent) -> Void)?

    private let identity: SecIdentity
    private let queue = DispatchQueue(label: "com.airmic.server", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [UUID: ClientConnection] = [:]
    private var sources: [UUID: MicSourceDescriptor] = [:]
    private var started = false
    private let maximumPhones = 8

    init(port: UInt16, identity: SecIdentity, audio: AudioMixer) {
        self.port = port
        self.identity = identity
        self.audio = audio
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            let openClients = Array(self.clients.values)
            self.clients.removeAll()
            for client in openClients { client.close() }
            self.sources.removeAll()
            self.audio.reset()
            self.started = false
        }
    }

    private func startLocked() {
        guard !started else { return }
        guard let secIdentity = sec_identity_create(identity) else {
            emit(.error("无法加载本地安全证书。"))
            return
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                emit(.error("端口 \(port) 无效。"))
                return
            }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.started = true
                    NSLog("AirMic HTTPS listening on port \(self.port)")
                    self.emit(.listening(port: self.port))
                case .failed(let error):
                    self.emit(.error("本地服务启动失败：\(error.localizedDescription)"))
                    self.listener?.cancel()
                    self.listener = nil
                    self.started = false
                case .cancelled:
                    self.started = false
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            emit(.error("无法监听端口 \(port)：\(error.localizedDescription)"))
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = ClientConnection(
            connection: connection,
            server: self,
            queue: queue,
            audio: audio
        )
        clients[client.id] = client
        client.start()
    }

    fileprivate func registerSource(
        client: ClientConnection,
        name: String,
        platform: String,
        sampleRate: Double
    ) -> MicSourceDescriptor? {
        guard sources.count < maximumPhones else { return nil }
        var channel = 1
        let used = Set(sources.values.map(\.channel))
        while used.contains(channel) { channel += 1 }

        let descriptor = MicSourceDescriptor(
            id: UUID(),
            name: name,
            platform: platform,
            channel: channel,
            sampleRate: sampleRate
        )
        sources[descriptor.id] = descriptor
        client.sourceID = descriptor.id
        client.channel = channel
        audio.addSource(id: descriptor.id, name: name, prebufferMilliseconds: 10)
        emit(.sourceAdded(descriptor))
        NSLog("AirMic source #\(channel) connected: \(name) at \(Int(sampleRate)) Hz")
        return descriptor
    }

    fileprivate func unregisterSource(client: ClientConnection) {
        guard let id = client.sourceID else { return }
        client.sourceID = nil
        sources.removeValue(forKey: id)
        audio.removeSource(id: id)
        emit(.sourceRemoved(id))
    }

    fileprivate func deactivate(client: ClientConnection) {
        clients.removeValue(forKey: client.id)
        if client.hasUpgraded && client.sourceID == nil {
            emit(.pageClosed)
        }
        unregisterSource(client: client)
    }

    fileprivate func relay(_ event: ServerEvent) {
        emit(event)
    }

    fileprivate func phoneCount() -> Int {
        sources.count
    }

    fileprivate func totalKbps() -> Double {
        clients.values
            .filter { $0.isStreaming }
            .reduce(0) { $0 + $1.currentKbps }
    }

    private func emit(_ event: ServerEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    fileprivate func healthJSON() -> Data {
        let snapshot = audio.snapshot()
        let sortedSources = sources.values.sorted { $0.channel < $1.channel }
        let sourceJSON: [[String: Any]] = sortedSources.map { source in
            let level = snapshot.sources.first(where: { $0.id == source.id })
            return [
                "id": source.id.uuidString,
                "name": source.name,
                "platform": source.platform,
                "channel": source.channel,
                "sampleRate": Int(source.sampleRate),
                "level": Double(level?.level ?? 0),
                "queueMs": Int((level?.queueMilliseconds ?? 0).rounded()),
                "muted": level?.muted ?? false
            ]
        }
        let payload: [String: Any] = [
            "status": "ok",
            "app": "AirMic",
            "port": Int(port),
            "clients": clients.count,
            "phones": sources.count,
            "streaming": !sources.isEmpty,
            "bufferMs": Int(snapshot.bufferMilliseconds.rounded()),
            "pendingMs": Int(snapshot.pendingMilliseconds.rounded()),
            "aheadMs": Int(snapshot.scheduledAheadMilliseconds.rounded()),
            "queueMs": Int(snapshot.queueMilliseconds.rounded()),
            "underruns": snapshot.underruns,
            "sampleRate": Int(snapshot.sampleRate),
            "outputLatencyMs": Int(snapshot.outputLatencyMilliseconds.rounded()),
            "engine": snapshot.engineRunning,
            "player": snapshot.playerRunning,
            "targetMs": Int(snapshot.targetAheadMilliseconds.rounded()),
            "silentChunks": snapshot.silentChunks,
            "droppedFrames": snapshot.droppedSourceFrames,
            "totalKbps": Int(totalKbps().rounded()),
            "sources": sourceJSON
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: - Connection

private final class ClientConnection {
    let id = UUID()
    private let connection: NWConnection
    private unowned let server: HTTPServer
    private let queue: DispatchQueue
    private let audio: AudioMixer
    private var buffer = Data()
    private var parser = WebSocketParser()
    private var upgraded = false
    private var closed = false
    private var hello = false
    private(set) var isStreaming = false
    private(set) var userAgent = ""
    fileprivate var sourceID: UUID?
    fileprivate var channel = 0
    fileprivate var hasUpgraded: Bool { upgraded }

    private var statsTimer: DispatchSourceTimer?
    private var statsTick = 0
    private var bytesSinceStats = 0
    private var lastStatsAt = Date()
    private var rttMilliseconds: Double = 0
    private var kbps: Double = 0
    fileprivate var currentKbps: Double { kbps }
    private var cachedSampleRate: Double = 48_000

    init(connection: NWConnection, server: HTTPServer, queue: DispatchQueue, audio: AudioMixer) {
        self.connection = connection
        self.server = server
        self.queue = queue
        self.audio = audio
    }

    deinit {
        statsTimer?.cancel()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveNext()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        statsTimer?.cancel()
        statsTimer = nil
        connection.cancel()
        server.deactivate(client: self)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        statsTimer?.cancel()
        statsTimer = nil
        server.deactivate(client: self)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if error != nil || isComplete {
                self.finish()
            } else if !self.closed {
                self.receiveNext()
            }
        }
    }

    private func consume(_ data: Data) {
        guard !closed else { return }
        if upgraded {
            parser.append(data)
            processWebSocketMessages()
            return
        }

        buffer.append(data)
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 {
                sendHTTP(status: "431 Request Header Fields Too Large", contentType: "text/plain", body: Data("Request too large".utf8))
            }
            return
        }

        let headerData = Data(buffer[buffer.startIndex..<headerEnd.lowerBound])
        let remainder = Data(buffer[headerEnd.upperBound..<buffer.endIndex])
        buffer.removeAll(keepingCapacity: false)
        handleHTTP(headerData)

        if upgraded, !remainder.isEmpty {
            parser.append(remainder)
            processWebSocketMessages()
        }
    }

    private func handleHTTP(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            sendHTTP(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTP(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        userAgent = headers["user-agent"] ?? ""

        guard method == "GET" || method == "HEAD" else {
            sendHTTP(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Method not allowed".utf8))
            return
        }
        let includeBody = method != "HEAD"

        if path == "/ws" {
            upgradeToWebSocket(headers: headers)
            return
        }

        switch path {
        case "/", "/index.html":
            sendHTTP(
                status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: PhoneResources.html,
                includeBody: includeBody,
                extraHeaders: ["Permissions-Policy": "microphone=(self)"]
            )
        case "/pcm-worklet.js":
            sendHTTP(
                status: "200 OK",
                contentType: "application/javascript; charset=utf-8",
                body: PhoneResources.worklet,
                includeBody: includeBody
            )
        case "/manifest.webmanifest":
            sendHTTP(
                status: "200 OK",
                contentType: "application/manifest+json; charset=utf-8",
                body: PhoneResources.manifest,
                includeBody: includeBody
            )
        case "/favicon.svg":
            sendHTTP(
                status: "200 OK",
                contentType: "image/svg+xml",
                body: PhoneResources.favicon,
                includeBody: includeBody
            )
        case "/favicon.ico":
            sendHTTP(status: "204 No Content", contentType: nil, body: Data(), includeBody: false)
        case "/health":
            sendHTTP(
                status: "200 OK",
                contentType: "application/json; charset=utf-8",
                body: server.healthJSON(),
                includeBody: includeBody
            )
        default:
            sendHTTP(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
        }
    }

    private func upgradeToWebSocket(headers: [String: String]) {
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().contains("upgrade") == true,
              let key = headers["sec-websocket-key"],
              headers["sec-websocket-version"] == "13" else {
            sendHTTP(status: "400 Bad Request", contentType: "text/plain", body: Data("Expected WebSocket upgrade".utf8))
            return
        }

        let accept = WebSocketCodec.acceptValue(for: key)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "",
            ""
        ].joined(separator: "\r\n")
        upgraded = true
        server.relay(.pageOpened(userAgent: userAgent))
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
        startStatsTimer()

        // A browser tab can disappear between the HTTP upgrade and its hello
        // message. Clean it up so it does not occupy a source slot.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.upgraded, !self.hello, !self.closed else { return }
            self.close()
        }
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(120))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        statsTimer = timer
        lastStatsAt = Date()
    }

    private func tick() {
        guard upgraded, !closed, hello else { return }
        statsTick += 1
        let now = Date()
        let interval = max(0.2, now.timeIntervalSince(lastStatsAt))
        let measuredKbps = Double(bytesSinceStats * 8) / 1000.0 / interval
        kbps = kbps == 0 ? measuredKbps : kbps * 0.65 + measuredKbps * 0.35
        bytesSinceStats = 0
        lastStatsAt = now

        if statsTick % 3 == 0 {
            sendJSON([
                "type": "ping",
                "t": now.timeIntervalSince1970 * 1000.0
            ])
        }

        let snapshot = audio.snapshot()
        let totalLatency = snapshot.bufferMilliseconds + rttMilliseconds / 2.0
        sendJSON([
            "type": "stats",
            "bufferMs": Int(snapshot.bufferMilliseconds.rounded()),
            "queueMs": Int(snapshot.queueMilliseconds.rounded()),
            "outputLatencyMs": Int(snapshot.outputLatencyMilliseconds.rounded()),
            "latencyMs": Int(totalLatency.rounded()),
            "rttMs": Int(rttMilliseconds.rounded()),
            "kbps": Int(kbps.rounded()),
            "level": Double(snapshot.level),
            "sampleRate": Int(snapshot.sampleRate),
            "phones": server.phoneCount(),
            "underruns": snapshot.underruns
        ])
        server.relay(.stats(
            rttMilliseconds: rttMilliseconds,
            kbps: server.totalKbps(),
            queueMilliseconds: snapshot.queueMilliseconds,
            outputLatencyMilliseconds: snapshot.outputLatencyMilliseconds,
            level: snapshot.level,
            sampleRate: snapshot.sampleRate,
            sources: snapshot.sources,
            phoneCount: server.phoneCount()
        ))
    }

    private func processWebSocketMessages() {
        while let message = parser.nextMessage() {
            switch message.opcode {
            case .text:
                handleText(message.payload)
            case .binary:
                bytesSinceStats += message.payload.count
                guard hello, let sourceID else { continue }
                audio.enqueue(pcm: message.payload, sampleRate: cachedSampleRate, sourceID: sourceID)
            case .ping:
                sendFrame(WebSocketCodec.frame(opcode: .pong, payload: message.payload))
            case .pong:
                break
            case .close:
                sendFrame(WebSocketCodec.close(code: 1000, reason: "bye"))
                queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.close()
                }
                return
            case .continuation:
                break
            }
        }
    }

    private func handleText(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "hello":
            guard !hello else { return }
            let sampleRate: Double
            if let value = object["sampleRate"] as? Double {
                sampleRate = value
            } else if let value = object["sampleRate"] as? Int {
                sampleRate = Double(value)
            } else {
                sampleRate = 48_000
            }
            let trimmedName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmedName?.isEmpty == false ? trimmedName! : "手机麦克风")
            let platform = object["platform"] as? String ?? "手机浏览器"
            cachedSampleRate = sampleRate.clamped(to: 8_000...192_000)

            guard let descriptor = server.registerSource(
                client: self,
                name: name,
                platform: platform,
                sampleRate: cachedSampleRate
            ) else {
                sendJSON(["type": "error", "message": "同时连接的手机已达上限（8 台）"])
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.close() }
                return
            }

            hello = true
            isStreaming = true
            lastStatsAt = Date()
            bytesSinceStats = 0
            sendJSON([
                "type": "ready",
                "sampleRate": cachedSampleRate,
                "targetBufferMs": 25,
                "channel": descriptor.channel,
                "server": "AirMic"
            ])
        case "ping":
            if let t = object["t"] {
                sendJSON(["type": "pong", "t": t])
            }
        case "pong":
            if let t = object["t"] as? Double {
                let measured = max(0, Date().timeIntervalSince1970 * 1000.0 - t)
                rttMilliseconds = rttMilliseconds == 0 ? measured : rttMilliseconds * 0.7 + measured * 0.3
            }
        case "bye":
            close()
        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        sendFrame(WebSocketCodec.text(text))
    }

    private func sendFrame(_ data: Data) {
        guard upgraded, !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
    }

    private func sendHTTP(
        status: String,
        contentType: String?,
        body: Data,
        includeBody: Bool = true,
        extraHeaders: [String: String] = [:]
    ) {
        var headers = [
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Connection": "close",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer"
        ]
        if let contentType { headers["Content-Type"] = contentType }
        headers["Content-Length"] = String(body.count)
        for (key, value) in extraHeaders { headers[key] = value }

        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        var data = Data(response.utf8)
        if includeBody { data.append(body) }

        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish()
            self?.connection.cancel()
        })
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Embedded phone resources

enum PhoneResources {
    static let html = load(name: "phone", extension: "html", fallback: fallbackHTML)
    static let worklet = load(name: "pcm-worklet", extension: "js", fallback: Data("registerProcessor('pcm-processor', class extends AudioWorkletProcessor { process() { return true } })".utf8))
    static let manifest = load(name: "manifest", extension: "webmanifest", fallback: Data("""
    {"name":"AirMic 手机麦克风","short_name":"AirMic","start_url":"/","display":"standalone","background_color":"#080D1A","theme_color":"#080D1A"}
    """.utf8))
    static let favicon = load(name: "favicon", extension: "svg", fallback: Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="16" fill="#0B1220"/><path d="M32 14a8 8 0 0 1 8 8v10a8 8 0 0 1-16 0V22a8 8 0 0 1 8-8zm-13 18a13 13 0 0 0 26 0M32 45v6" fill="none" stroke="#5EEAD4" stroke-width="4" stroke-linecap="round"/></svg>
    """.utf8))

    private static func load(name: String, extension ext: String, fallback: Data) -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            return fallback
        }
        return data
    }

    private static let fallbackHTML = Data("""
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <body style="font-family:-apple-system;background:#080D1A;color:#fff;padding:32px">
    <h1>AirMic</h1><p>手机页面资源缺失，请重新安装 App。</p></body>
    """.utf8)
}
