import AppKit
import Foundation
import CoreAudio

struct MicSourceUI: Identifiable, Equatable {
    let id: UUID
    var name: String
    var platform: String
    var channel: Int
    var sampleRate: Double
    var level: Float = 0
    var queueMilliseconds: Double = 0
    var isMuted: Bool = false
    var isLocal: Bool = false
    var isSystemInput: Bool = false
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case waiting
        case pageOpen
        case live
        case error
    }

    static let localSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let systemMicSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var serverURL: URL?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var ipAddress = ""
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var serverReady = false
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var bufferMilliseconds = 0
    @Published private(set) var queueMilliseconds = 0
    @Published private(set) var outputLatencyMilliseconds = 0
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var selectedOutputDeviceID: AudioDeviceID?
    @Published private(set) var systemDefaultOutputID: AudioDeviceID?
    @Published private(set) var rttMilliseconds = 0
    @Published private(set) var kbps = 0
    @Published private(set) var underruns = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var sessionSeconds = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var sources: [MicSourceUI] = []
    @Published private(set) var localMicEnabled = false
    @Published private(set) var localMicBusy = false
    @Published private(set) var systemInputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedSystemInputUID: String?
    @Published private(set) var systemMicEnabled = false
    @Published private(set) var systemMicBusy = false
    @Published private(set) var systemMicDeviceName = ""
    @Published var notice: String?
    @Published var copied = false
    @Published var volume: Double = 0.9 {
        didSet { audio?.setVolume(Float(volume)) }
    }

    private var server: HTTPServer?
    private var audio: AudioMixer?
    private var localMic: LocalMicCapture?
    private var systemMic: SystemMicCapture?
    private var previousSystemInputID: AudioDeviceID?
    private var inputRefreshTick = 0
    private var sessionTimer: Timer?
    private var networkTimer: Timer?
    private var audioStatsTimer: Timer?
    private var noticeWorkItem: DispatchWorkItem?
    private var sessionStartedAt: Date?
    private let outputDeviceUIDKey = "airmic.outputDeviceUID"
    private let systemInputUIDKey = "airmic.systemInputUID"

    init() {
        start()
        startNetworkMonitor()
        startAudioStatsMonitor()
        if ProcessInfo.processInfo.environment["AIRMIC_IPHONE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.setSystemMic(true)
            }
        }
    }

    deinit {
        sessionTimer?.invalidate()
        networkTimer?.invalidate()
        audioStatsTimer?.invalidate()
    }

    // MARK: - Derived UI state

    var outputDeviceName: String {
        guard let selectedOutputDeviceID else { return "系统默认输出" }
        return outputDevices.first(where: { $0.id == selectedOutputDeviceID })?.name
            ?? AudioDevices.name(for: selectedOutputDeviceID)
    }

    var outputDeviceIsBluetooth: Bool {
        guard let selectedOutputDeviceID else { return false }
        return AudioDevices.isBluetooth(selectedOutputDeviceID)
    }

    var selectedOutputDevice: AudioDevice? {
        guard let selectedOutputDeviceID else { return nil }
        return outputDevices.first(where: { $0.id == selectedOutputDeviceID })
    }

    var isKaraokeOutputUnified: Bool {
        guard let selectedOutputDeviceID, let systemDefaultOutputID else { return false }
        return selectedOutputDeviceID == systemDefaultOutputID
    }

    var systemDefaultOutputName: String {
        guard let systemDefaultOutputID else { return "系统默认输出" }
        return outputDevices.first(where: { $0.id == systemDefaultOutputID })?.name
            ?? AudioDevices.name(for: systemDefaultOutputID)
    }

    var isUsingSystemDefaultOutput: Bool {
        guard let selectedOutputDeviceID, let systemDefaultOutputID else { return false }
        return selectedOutputDeviceID == systemDefaultOutputID
    }

    var outputDeviceHint: String {
        guard let device = selectedOutputDevice else { return "选择播放声音的音箱" }
        if device.isBluetooth { return "蓝牙输出 · 延迟较高" }
        if device.isBuiltIn { return "内置扬声器 · 最低延迟" }
        return "外接输出"
    }

    var phoneSources: [MicSourceUI] {
        sources.filter { !$0.isLocal && !$0.isSystemInput }
    }

    var localSource: MicSourceUI? {
        sources.first(where: { $0.isLocal })
    }

    var systemSource: MicSourceUI? {
        sources.first(where: { $0.isSystemInput })
    }

    var selectedSystemInput: AudioInputDevice? {
        guard let selectedSystemInputUID else { return systemInputDevices.first }
        return systemInputDevices.first(where: { $0.uid == selectedSystemInputUID })
            ?? systemInputDevices.first
    }

    var phoneCount: Int { phoneSources.count }

    var statusTitle: String {
        switch phase {
        case .starting: return "正在准备服务…"
        case .waiting: return "等待手机连接"
        case .pageOpen: return "手机已连接"
        case .live:
            if phoneCount > 0 && localMicEnabled {
                return "\(phoneCount) 路手机 + 本机扩音"
            }
            if phoneCount > 0 {
                return phoneCount == 1 ? "正在传音" : "正在传音 · \(phoneCount) 路"
            }
            return "本地扩音中"
        case .error: return "服务出现异常"
        }
    }

    var statusDetail: String {
        switch phase {
        case .starting:
            return "正在生成本地安全证书并启动服务"
        case .waiting:
            return "用手机扫描左侧二维码，可同时连接多台手机"
        case .pageOpen:
            return "请在手机上点击「开始传音」"
        case .live:
            if localMicEnabled && phoneCount == 0 {
                return "Mac 麦克风正在直接扩音 · 建议使用耳机避免啸叫"
            }
            return "多路声音正在实时混合到这台 Mac"
        case .error:
            return errorMessage ?? "请重新打开 App 试试"
        }
    }

    var latencyMilliseconds: Int {
        guard phase == .live else { return 0 }
        return max(0, Int((Double(queueMilliseconds + outputLatencyMilliseconds) + Double(rttMilliseconds) / 2.0).rounded()))
    }

    var qualityLabel: String {
        String(format: "%.1f kHz · 16-bit", (sampleRate > 0 ? sampleRate : 48_000) / 1000.0)
    }

    var sessionTimeLabel: String {
        let minutes = sessionSeconds / 60
        let seconds = sessionSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var isLive: Bool { phase == .live }

    // MARK: - Lifecycle

    private func start() {
        do {
            let address = NetworkInfo.primaryIPv4()
                ?? NetworkAddress(ip: "127.0.0.1", interface: "lo0")
            ipAddress = address.ip
            port = NetworkInfo.availablePort(startingAt: 8765)
            refreshOutputDeviceList(preferred: AudioDevices.recommendedOutputDevice())
            refreshInputDeviceList()

            let certificates = try CertificateManager()
            let identity = try certificates.loadOrCreateIdentity(for: address)

            let mixer = AudioMixer(outputDeviceID: selectedOutputDeviceID)
            mixer.onError = { [weak self] message in
                self?.showError(message)
            }
            audio = mixer
            mixer.setVolume(Float(volume))

            let capture = LocalMicCapture()
            capture.onSamples = { [weak mixer] samples, rate in
                mixer?.enqueue(samples: samples, sampleRate: rate, sourceID: AppModel.localSourceID)
            }
            capture.onError = { [weak self] message in
                self?.showNotice(message)
            }
            localMic = capture

            let server = HTTPServer(port: port, identity: identity, audio: mixer)
            server.onEvent = { [weak self] event in
                self?.handle(event)
            }
            self.server = server
            updateURL()
            server.start()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func startAudioStatsMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMixer()
                self?.inputRefreshTick += 1
                if let tick = self?.inputRefreshTick, tick % 8 == 0 {
                    self?.refreshInputDeviceList()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioStatsTimer = timer
    }

    private func pollMixer() {
        guard let snapshot = audio?.snapshot(), !sources.isEmpty || localMicEnabled || systemMicEnabled else { return }
        queueMilliseconds = Int(snapshot.queueMilliseconds.rounded())
        outputLatencyMilliseconds = Int(snapshot.outputLatencyMilliseconds.rounded())
        bufferMilliseconds = queueMilliseconds + outputLatencyMilliseconds
        level = snapshot.level
        underruns = snapshot.underruns
        applySourceLevels(snapshot.sources)
    }

    private func startNetworkMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkNetwork()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        networkTimer = timer
    }

    private func checkNetwork() {
        refreshOutputDeviceList(preferred: nil)
        guard let address = NetworkInfo.primaryIPv4(), address.ip != ipAddress, serverReady else { return }
        ipAddress = address.ip
        updateURL()
        showNotice("网络地址已更新，请用新二维码重新连接")
    }

    private func refreshOutputDeviceList(preferred: AudioDevice?) {
        let devices = AudioDevices.outputDevices()
        outputDevices = devices
        systemDefaultOutputID = AudioDevices.defaultOutputDeviceID()

        if let selectedOutputDeviceID, devices.contains(where: { $0.id == selectedOutputDeviceID }) {
            return
        }

        let oldID = selectedOutputDeviceID
        let savedUID = UserDefaults.standard.string(forKey: outputDeviceUIDKey)
        let savedDevice = savedUID.flatMap { uid in devices.first(where: { $0.uid == uid }) }
        let systemDefaultDevice = systemDefaultOutputID.flatMap { id in
            devices.first(where: { $0.id == id })
        }
        // Follow the Mac's current output by default so the user hears sound
        // immediately; the selector can switch to the built-in low-latency path.
        let target = savedDevice ?? systemDefaultDevice ?? preferred ?? AudioDevices.recommendedOutputDevice()
        if let target {
            selectedOutputDeviceID = target.id
            UserDefaults.standard.set(target.uid, forKey: outputDeviceUIDKey)
            if oldID != nil, oldID != target.id {
                audio?.setOutputDevice(target.id)
            }
        }
    }

    func refreshInputDeviceList() {
        let availableUIDs = Set(SystemMicCapture.availableContinuityDevices().map(\.uniqueID))
        let devices = AudioDevices.inputDevices().filter {
            $0.isContinuity && (availableUIDs.isEmpty || availableUIDs.contains($0.uid))
        }
        systemInputDevices = devices
        let savedUID = UserDefaults.standard.string(forKey: systemInputUIDKey)
        if let selectedSystemInputUID, devices.contains(where: { $0.uid == selectedSystemInputUID }) {
            return
        }
        let target = savedUID.flatMap { uid in devices.first(where: { $0.uid == uid }) } ?? devices.first
        selectedSystemInputUID = target?.uid
        if let target {
            UserDefaults.standard.set(target.uid, forKey: systemInputUIDKey)
        }
        if systemMicEnabled, target == nil {
            setSystemMic(false)
        }
    }

    func selectSystemInput(_ device: AudioInputDevice) {
        let changed = selectedSystemInputUID != device.uid
        selectedSystemInputUID = device.uid
        UserDefaults.standard.set(device.uid, forKey: systemInputUIDKey)
        guard changed, systemMicEnabled, !systemMicBusy else { return }
        systemMic?.stop()
        systemMic = nil
        systemMicEnabled = false
        audio?.removeSource(id: Self.systemMicSourceID)
        sources.removeAll(where: { $0.isSystemInput })
        setSystemMic(true)
    }

    func setSystemMic(_ enabled: Bool) {
        guard enabled != systemMicEnabled, !systemMicBusy else { return }
        guard let audio else { return }

        if !enabled {
            systemMic?.stop()
            systemMic = nil
            systemMicEnabled = false
            systemMicDeviceName = ""
            if let previousSystemInputID, previousSystemInputID != 0 {
                AudioDevices.setSystemDefaultInput(deviceID: previousSystemInputID)
            }
            previousSystemInputID = nil
            audio.removeSource(id: Self.systemMicSourceID)
            sources.removeAll(where: { $0.isSystemInput })
            if sources.isEmpty && !localMicEnabled {
                endSession()
                phase = serverReady ? .waiting : .starting
                resetLiveMeasurementsIfNeeded()
            }
            return
        }

        guard let device = selectedSystemInput else {
            showNotice("没有找到 iPhone 麦克风。请先在系统设置 → 声音 → 输入中选择 iPhone。")
            AudioDevices.openSoundInputSettings()
            return
        }

        systemMicBusy = true
        SystemMicCapture.requestedPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.systemMicBusy = false
                guard granted else {
                    self.showNotice("麦克风权限被拒绝：请到系统设置 → 隐私与安全性 → 麦克风中允许「Mac 音频枢纽」")
                    return
                }
                let available = SystemMicCapture.availableContinuityDevices()
                guard let avDevice = available.first(where: { $0.uniqueID == device.uid }) ?? available.first else {
                    self.showNotice("iPhone 麦克风不在线：请解锁 iPhone、靠近 Mac，并在系统声音输入里确认设备。")
                    AudioDevices.openSoundInputSettings()
                    return
                }

                let capture = SystemMicCapture()
                capture.onSamples = { [weak audio] samples, rate in
                    audio?.enqueue(samples: samples, sampleRate: rate, sourceID: AppModel.systemMicSourceID)
                }
                capture.onError = { [weak self] message in
                    self?.showNotice(message)
                }

                // Add the source BEFORE starting the capture session. Starting a
                // Continuity session can take a few seconds, and audio frames
                // arrive immediately; without the source they would be dropped.
                audio.addSource(
                    id: Self.systemMicSourceID,
                    name: avDevice.localizedName,
                    prebufferMilliseconds: 15,
                    maxQueueMilliseconds: 40
                )
                self.systemMic = capture
                self.systemMicEnabled = true
                self.systemMicDeviceName = avDevice.localizedName
                self.sources.removeAll(where: { $0.isSystemInput })
                self.sources.append(MicSourceUI(
                    id: Self.systemMicSourceID,
                    name: avDevice.localizedName,
                    platform: "iPhone · Apple Continuity",
                    channel: 0,
                    sampleRate: 48_000,
                    isSystemInput: true
                ))
                self.sortSources()
                self.selectedSystemInputUID = avDevice.uniqueID
                UserDefaults.standard.set(avDevice.uniqueID, forKey: self.systemInputUIDKey)
                self.phase = .live
                self.beginSession()

                let previous = AudioDevices.systemDefaultInputDeviceID()
                self.previousSystemInputID = previous
                let targetID = AudioDevices.inputDevices()
                    .first(where: { $0.uid == avDevice.uniqueID })?.id ?? device.id
                let switched = AudioDevices.setSystemDefaultInput(deviceID: targetID)
                NSLog("AirMic system mic start name=%@ av=%@ uid=%@ defaultSet=%@", device.shortName, avDevice.localizedName, avDevice.uniqueID, switched ? "yes" : "no")

                // AVCaptureSession.startRunning is blocking; never run it on the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try capture.start(device: avDevice)
                        DispatchQueue.main.async { [weak self] in
                            self?.showNotice("已接入 \(avDevice.localizedName)（Apple 连续互通麦克风）")
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            capture.stop()
                            audio.removeSource(id: Self.systemMicSourceID)
                            self.sources.removeAll(where: { $0.isSystemInput })
                            self.systemMic = nil
                            self.systemMicEnabled = false
                            self.systemMicDeviceName = ""
                            if let previous, previous != 0 {
                                AudioDevices.setSystemDefaultInput(deviceID: previous)
                            }
                            self.previousSystemInputID = nil
                            if self.sources.isEmpty && !self.localMicEnabled {
                                self.endSession()
                                self.phase = self.serverReady ? .waiting : .starting
                            }
                            self.showNotice("无法启动 iPhone 麦克风：\(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func updateURL() {
        guard port > 0, !ipAddress.isEmpty else { return }
        let url = URL(string: "https://\(ipAddress):\(port)/")
        serverURL = url
        qrImage = url.flatMap { QRCodeGenerator.makeImage(for: $0.absoluteString) }
    }

    // MARK: - Events

    private func handle(_ event: ServerEvent) {
        switch event {
        case .listening:
            serverReady = true
            if sources.isEmpty && !localMicEnabled && phase == .starting {
                phase = .waiting
            }
        case .pageOpened:
            if sources.isEmpty && !localMicEnabled {
                phase = .pageOpen
            }
        case .pageClosed:
            if sources.isEmpty && !localMicEnabled && phase == .pageOpen {
                phase = serverReady ? .waiting : .starting
            }
        case .sourceAdded(let descriptor):
            let source = MicSourceUI(
                id: descriptor.id,
                name: descriptor.name,
                platform: descriptor.platform,
                channel: descriptor.channel,
                sampleRate: descriptor.sampleRate
            )
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index] = source
            } else {
                sources.append(source)
            }
            sortSources()
            sampleRate = descriptor.sampleRate
            errorMessage = nil
            phase = .live
            beginSession()
        case .sourceRemoved(let id):
            sources.removeAll(where: { $0.id == id })
            resetLiveMeasurementsIfNeeded()
            if sources.isEmpty && !localMicEnabled {
                endSession()
                phase = serverReady ? .waiting : .starting
            }
            showNotice("一路麦克风已断开")
        case .stats(let rtt, let kbps, let queue, let outputLatency, let level, let rate, let sourceLevels, let phoneCount):
            rttMilliseconds = Int(rtt.rounded())
            self.kbps = Int(kbps.rounded())
            queueMilliseconds = Int(queue.rounded())
            outputLatencyMilliseconds = Int(outputLatency.rounded())
            bufferMilliseconds = queueMilliseconds + outputLatencyMilliseconds
            self.level = level
            if rate > 0 { sampleRate = rate }
            applySourceLevels(sourceLevels)
            if phoneCount == 0 && !localMicEnabled && sources.isEmpty {
                phase = serverReady ? .waiting : .starting
            }
        case .error(let message):
            showError(message)
        }
    }

    private func applySourceLevels(_ levels: [MixSourceLevel]) {
        for index in sources.indices {
            if let level = levels.first(where: { $0.id == sources[index].id }) {
                sources[index].level = level.level
                sources[index].queueMilliseconds = level.queueMilliseconds
                sources[index].isMuted = level.muted
            } else {
                sources[index].level *= 0.90
            }
        }
    }

    private func sortSources() {
        sources.sort {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.channel < $1.channel
        }
    }

    private func resetLiveMeasurementsIfNeeded() {
        guard sources.isEmpty && !localMicEnabled else { return }
        level = 0
        bufferMilliseconds = 0
        queueMilliseconds = 0
        outputLatencyMilliseconds = 0
        rttMilliseconds = 0
        kbps = 0
        underruns = 0
    }

    private func beginSession() {
        guard sessionStartedAt == nil else { return }
        sessionStartedAt = Date()
        sessionSeconds = 0
        sessionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.sessionStartedAt else { return }
                self.sessionSeconds = Int(Date().timeIntervalSince(started))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer
    }

    private func endSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionStartedAt = nil
    }

    private func showError(_ message: String) {
        errorMessage = message
        phase = .error
    }

    private func showNotice(_ message: String) {
        noticeWorkItem?.cancel()
        notice = message
        let item = DispatchWorkItem { [weak self] in
            self?.notice = nil
        }
        noticeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: item)
    }

    // MARK: - User actions

    func copyURL() {
        guard let serverURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(serverURL.absoluteString, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copied = false
        }
    }

    func selectOutputDevice(_ device: AudioDevice) {
        selectedOutputDeviceID = device.id
        UserDefaults.standard.set(device.uid, forKey: outputDeviceUIDKey)
        audio?.setOutputDevice(device.id)
        queueMilliseconds = 0
        outputLatencyMilliseconds = 0
        if device.isBluetooth {
            showNotice("已切换到蓝牙输出「\(device.name)」，延迟会明显增加")
        } else {
            showNotice("输出已切换到「\(device.name)」")
        }
    }

    func selectLowLatencyOutput() {
        let candidates = outputDevices.filter { !$0.isBluetooth }
        guard let device = candidates.first(where: { $0.isBuiltIn }) ?? candidates.first else {
            showNotice("没有检测到可用的内置或有线输出")
            return
        }
        activateKaraokeOutput(device)
    }

    /// K歌时音乐由平台 App 直接播放，必须让人声和平台音乐走同一个物理输出，
    /// 否则会出现“音乐在 JBL、人声在内置扬声器”的错位。
    func activateKaraokeOutput(_ device: AudioDevice) {
        let changedSystem = AudioDevices.setSystemDefaultOutput(deviceID: device.id)
        selectOutputDevice(device)
        if changedSystem {
            showNotice("音乐和人声已统一到 \(device.name)")
        } else {
            showNotice("已切换人声输出；如音乐仍在其他音箱，请在系统设置中切换输出")
        }
    }

    func useSystemDefaultOutput() {
        guard let id = systemDefaultOutputID,
              let device = outputDevices.first(where: { $0.id == id }) else {
            showNotice("没有检测到系统默认输出设备")
            return
        }
        selectOutputDevice(device)
    }

    func setLocalMic(_ enabled: Bool) {
        guard enabled != localMicEnabled, !localMicBusy else { return }
        guard let audio else { return }

        if !enabled {
            localMic?.stop()
            localMicEnabled = false
            audio.removeSource(id: Self.localSourceID)
            sources.removeAll(where: { $0.isLocal })
            if sources.isEmpty {
                endSession()
                phase = serverReady ? .waiting : .starting
                resetLiveMeasurementsIfNeeded()
            }
            return
        }

        localMicBusy = true
        LocalMicCapture.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.localMicBusy = false
                guard granted else {
                    self.showNotice("麦克风权限被拒绝：请到系统设置 → 隐私与安全性 → 麦克风中允许「Mac 音频枢纽」")
                    return
                }
                do {
                    try self.localMic?.start()
                    audio.addSource(
                        id: Self.localSourceID,
                        name: "本机麦克风",
                        prebufferMilliseconds: 15,
                        maxQueueMilliseconds: 30
                    )
                    self.localMicEnabled = true
                    self.sources.removeAll(where: { $0.isLocal })
                    self.sources.append(MicSourceUI(
                        id: Self.localSourceID,
                        name: "本机麦克风",
                        platform: "Mac 内置/默认输入",
                        channel: 0,
                        sampleRate: 48_000,
                        isLocal: true
                    ))
                    self.sortSources()
                    self.phase = .live
                    self.beginSession()
                    self.showNotice("本地麦克风已开启，请使用耳机避免啸叫")
                } catch {
                    self.localMic?.stop()
                    self.showNotice("无法启动本地麦克风：\(error.localizedDescription)")
                }
            }
        }
    }

    func toggleMute(_ source: MicSourceUI) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        let newValue = !sources[index].isMuted
        sources[index].isMuted = newValue
        audio?.setMuted(id: source.id, muted: newValue)
    }

    func restart() {
        localMic?.stop()
        systemMic?.stop()
        if let previousSystemInputID, previousSystemInputID != 0 {
            AudioDevices.setSystemDefaultInput(deviceID: previousSystemInputID)
        }
        previousSystemInputID = nil
        server?.stop()
        server = nil
        audio = nil
        localMic = nil
        systemMic = nil
        sources.removeAll()
        localMicEnabled = false
        systemMicEnabled = false
        systemMicDeviceName = ""
        endSession()
        phase = .starting
        serverReady = false
        errorMessage = nil
        level = 0
        bufferMilliseconds = 0
        queueMilliseconds = 0
        outputLatencyMilliseconds = 0
        rttMilliseconds = 0
        kbps = 0
        sampleRate = 48_000
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.start()
        }
    }

    func refreshNetwork() {
        guard let address = NetworkInfo.primaryIPv4() else {
            showNotice("没有检测到 Wi-Fi 或有线网络")
            return
        }
        if address.ip != ipAddress {
            ipAddress = address.ip
            updateURL()
            showNotice("网络地址已更新，请重新扫码")
        } else {
            updateURL()
            showNotice("二维码已刷新")
        }
    }

    func testTone() {
        audio?.playTestTone()
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        localMic?.stop()
        server?.stop()
        NSApplication.shared.terminate(nil)
    }
}
