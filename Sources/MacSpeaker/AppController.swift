import Foundation
import Network
import ScreenCaptureKit
import AppKit
import CoreGraphics

/// 协调音频引擎与推流服务器
final class AppController: AudioEngineDelegate {

    let model: SpeakerModel
    private let server: SpeakerServer
    private let audio = AudioEngine()
    private var started = false
    private var checkingPermission = false
    private var requestedScreenPermission = false

    init(model: SpeakerModel = SpeakerModel()) {
        self.model = model
        server = SpeakerServer(model: model)
        audio.delegate = self
        server.onClientRequestedStart = { [weak self] in
            self?.ensureCapture()
        }
        server.onClientRequestedStop = { [weak self] in
            self?.reconcileCapture()
        }
        server.onDeviceListChanged = { [weak self] in
            self?.reconcileCapture()
        }
        server.onServerFailed = { [weak self] msg in
            DispatchQueue.main.async {
                self?.model.serverRunning = false
                self?.model.serverError = msg
            }
        }
    }

    // MARK: - 启动 / 停止

    func start(checkPermission: Bool = true) {
        guard !started else { return }
        started = true
        model.ipAddresses = Self.ipAddresses()
        let port = Self.findFreePort(startingAt: model.port)
        model.port = port
        do {
            try server.start(port: port)
            model.serverRunning = true
            model.serverError = nil
        } catch {
            model.serverRunning = false
            model.serverError = "无法启动局域网服务：\(error.localizedDescription)"
        }
        // 合并版由界面在打开「Mac 音箱」页时再检测，避免只用麦克风时也弹权限框
        if checkPermission {
            checkScreenPermission()
        }
        // 恢复高效传输模式设置
        let eff = UserDefaults.standard.bool(forKey: "efficientMode")
        model.efficientMode = eff
        server.setEfficientMode(eff)
    }

    /// 切换高效传输模式（16bit，带宽减半，音质几乎无损）
    func setEfficientMode(_ on: Bool) {
        model.efficientMode = on
        UserDefaults.standard.set(on, forKey: "efficientMode")
        server.setEfficientMode(on)
    }

    func shutdown() {
        setCaptureEnabled(false)
        server.stop()
        started = false
    }

    // MARK: - 捕获开关（Mac 端主开关）

    func setCaptureEnabled(_ on: Bool) {
        model.captureEnabled = on
        reconcileCapture()
    }

    /// 设备请求播放时确保捕获运行
    private func ensureCapture() {
        guard model.captureEnabled || server.activeClientCount > 0 else { return }
        guard !audio.isCapturing else { return }
        Task { await audio.start() }
    }

    /// 根据设备数量与主开关重算是否应该捕获
    private func reconcileCapture() {
        let shouldCapture = model.captureEnabled && server.activeClientCount > 0
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if shouldCapture {
                if !self.audio.isCapturing {
                    Task { await self.audio.start() }
                }
            } else {
                if self.audio.isCapturing {
                    Task { await self.audio.stop() }
                    self.broadcastPlaying(false)
                }
            }
        }
    }

    /// 切换某台设备的推流状态
    func toggleDevice(_ id: UUID, active: Bool) {
        server.setDeviceActive(id: id, active: active)
    }

    private func broadcastPlaying(_ playing: Bool) {
        server.broadcastControl(jsonData(["type": "state", "playing": playing]))
    }

    // MARK: - 屏幕录制权限（授权引导）

    /// 检测当前是否已获得「屏幕录制」权限，并同步到界面
    func checkScreenPermission() {
        guard !checkingPermission else { return }
        checkingPermission = true
        Task { [weak self] in
            let ok = await Self.hasScreenCapturePermission()
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.hasScreenPermission = ok
                self.checkingPermission = false
            }
        }
    }

    static func hasScreenCapturePermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    /// SCShareableContent 不会弹授权框。CGRequestScreenCaptureAccess 能触发
    /// 系统原生的屏幕录制授权提示/引导，这是首次授权最可靠的方式。
    func requestScreenRecordingPermission() {
        guard !requestedScreenPermission else {
            checkScreenPermission()
            return
        }
        requestedScreenPermission = true
        if CGPreflightScreenCaptureAccess() {
            model.hasScreenPermission = true
            checkScreenPermission()
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            model.hasScreenPermission = true
        } else {
            openScreenRecordingSettings()
        }
        checkScreenPermission()
    }

    /// macOS 对屏幕录制不弹授权框，只允许在设置里手动添加。重置旧签名留下的
    /// TCC 记录后再打开设置，用户点 + 选择当前 App 即可。
    func resetScreenRecordingPermission() {
        requestedScreenPermission = false
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.airmic.local"]
        try? task.run()
        task.waitUntilExit()
        openScreenRecordingSettings()
    }

    /// 打开系统设置的「屏幕录制」授权页
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重启本应用（macOS 要求：屏幕录制授权后必须重启应用才生效）
    func restartApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundleURL.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - AudioEngineDelegate

    func audioEngineDidStart() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.model.isCapturing = true
            self.model.captureError = nil
            self.model.hasScreenPermission = true
        }
        broadcastPlaying(true)
    }

    func audioEngineDidStop() {
        DispatchQueue.main.async { [weak self] in
            self?.model.isCapturing = false
        }
        broadcastPlaying(false)
    }

    func audioEngine(_ engine: AudioEngine, error: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.model.isCapturing = false
            self.model.captureError = error
            if error.contains("屏幕录制") || error.contains("权限") {
                self.model.hasScreenPermission = false
            }
            self.server.broadcastControl(jsonData(["type": "error", "message": error]))
        }
    }

    func audioEngine(_ engine: AudioEngine, outputPCM data: Data, sampleRate: Double, channels: Int) {
        server.broadcastAudio(data)
    }

    // MARK: - 工具

    /// 获取本机局域网 IPv4 地址
    static func ipAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let addr = String(cString: host)
                    if !addr.hasPrefix("127.") && !addr.hasPrefix("169.254.") {
                        addresses.append(addr)
                    }
                }
            }
            ptr = interface.ifa_next
        }
        freeifaddrs(ifaddr)
        return addresses
    }

    /// 从起始端口开始找第一个空闲端口（SO_REUSEADDR 允许复用 TIME_WAIT 端口，避免重启漂移）
    static func findFreePort(startingAt start: UInt16) -> UInt16 {
        for port in start...UInt16(max(start, 9000)) {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            if socketFD < 0 { return start }
            var reuse: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(port)
            addr.sin_addr.s_addr = INADDR_ANY
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(socketFD)
            if bindResult == 0 { return port }
        }
        return start
    }
}
