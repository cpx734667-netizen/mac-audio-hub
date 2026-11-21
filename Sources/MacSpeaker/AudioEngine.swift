import Foundation
import CoreMedia
import ScreenCaptureKit

/// 音频引擎回调
protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidStart()
    func audioEngineDidStop()
    func audioEngine(_ engine: AudioEngine, outputPCM data: Data, sampleRate: Double, channels: Int)
    func audioEngine(_ engine: AudioEngine, error: String)
}

/// 使用 ScreenCaptureKit 捕获 Mac 系统正在播放的音频（无需虚拟声卡）
/// 输出格式固定为：48000 Hz、双声道、交错 Float32（小端）
final class AudioEngine: NSObject, SCStreamOutput {

    static let sampleRate = 48000
    static let channels = 2

    weak var delegate: AudioEngineDelegate?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.macspeaker.audio", qos: .userInteractive)
    private(set) var isCapturing = false
    private var loggedFirst = false
    private var frameCount = 0
    private var starting = false
    private let lock = NSLock()

    func start() async {
        lock.lock()
        if stream != nil || starting {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()
        defer {
            lock.lock()
            starting = false
            lock.unlock()
        }
        do {
            // 未授权时 displays 为空或抛出错误
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("[audio] 启动失败：displays 为空（无屏幕录制权限）")
                delegate?.audioEngine(self, error: Self.permissionDeniedMessage)
                return
            }
            print("[audio] 检测到显示器 \(display.width)x\(display.height)")

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = Self.sampleRate
            config.channelCount = Self.channels
            config.excludesCurrentProcessAudio = true
            config.queueDepth = 4

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await s.startCapture()
            lock.lock()
            stream = s
            isCapturing = true
            lock.unlock()
            print("[audio] 音频捕获已启动")
            delegate?.audioEngineDidStart()
        } catch {
            print("[audio] 捕获启动失败: \(error)")
            delegate?.audioEngine(self, error: Self.friendlyError(error))
        }
    }

    /// 权限被拒时给用户的友好提示
    static let permissionDeniedMessage = """
    没有获得「屏幕录制」权限，无法捕获系统音频。请按以下步骤操作：
    1. 打开「系统设置 → 隐私与安全性 → 屏幕录制」；
    2. 勾选「Mac 音箱」；
    3. 完全退出本应用（Cmd+Q），再重新打开；
    4. 设备端重新点击「开始播放」，在弹出的授权框中点「允许」。
    """

    /// 把系统错误转成可操作的提示
    private static func friendlyError(_ error: Error) -> String {
        let desc = "\(error)"
        let low = desc.lowercased()
        if low.contains("userdeclined") || low.contains("user refused") || low.contains("denied") || low.contains("not determined") || low.contains("permission") {
            return permissionDeniedMessage
        }
        return "启动音频捕获失败：\(error.localizedDescription)"
    }

    func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
        isCapturing = false
        delegate?.audioEngineDidStop()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        frameCount += 1
        if !loggedFirst {
            loggedFirst = true
            var sr = 0.0, ch = 0
            if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                sr = asbd.pointee.mSampleRate
                ch = Int(asbd.pointee.mChannelsPerFrame)
            }
            print("[audio] 首帧: sampleRate=\(sr) channels=\(ch) formatID=\(CMSampleBufferGetFormatDescription(sampleBuffer) != nil ? "ok" : "nil")")
        }
        if frameCount % 1000 == 0 {
            print("[audio] 帧计数: \(frameCount)")
        }
        guard let pcm = extractInterleavedFloat32(sampleBuffer) else {
            if frameCount < 5 {
                print("[audio] 第\(frameCount)帧提取失败")
            }
            return
        }
        delegate?.audioEngine(self, outputPCM: pcm, sampleRate: Double(Self.sampleRate), channels: Self.channels)
    }

    // MARK: - PCM 提取

    /// 将 CMSampleBuffer 中的音频统一转为「交错 Float32」字节流
    private func extractInterleavedFloat32(_ sb: CMSampleBuffer) -> Data? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else {
            if frameCount < 5 { print("[audio] 提取失败: 无格式描述") }
            return nil
        }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0 else {
            if frameCount < 5 {
                print("[audio] 提取失败: formatID=\(asbd.mFormatID) channels=\(asbd.mChannelsPerFrame) rate=\(asbd.mSampleRate)")
            }
            return nil
        }

        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        guard bytesPerSample == 2 || bytesPerSample == 4 else {
            if frameCount < 5 {
                print("[audio] 提取失败: bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)")
            }
            return nil
        }

        // 先查询所需的 AudioBufferList 大小，再按需分配
        var needed = 0
        var blockBuffer: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        if sizeStatus != noErr || needed <= 0 {
            if frameCount < 5 { print("[audio] 提取失败: sizeStatus=\(sizeStatus) needed=\(needed)") }
            return nil
        }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { storage.deallocate() }
        let ablPtr = storage.assumingMemoryBound(to: AudioBufferList.self)
        ablPtr.initialize(to: AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)))
        defer { ablPtr.deinitialize(count: 1) }

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: needed,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            if frameCount < 5 { print("[audio] 提取失败: status=\(status) needed=\(needed)") }
            return nil
        }
        if frameCount < 3 {
            print("[audio] ABL: buffers=\(ablPtr.pointee.mNumberBuffers) needed=\(needed)")
        }

        let bufferCount = Int(ablPtr.pointee.mNumberBuffers)
        guard bufferCount > 0 else { return nil }
        let buffers = (0..<bufferCount).map { i -> AudioBuffer in
            withUnsafeBytes(of: &ablPtr.pointee.mBuffers) { raw in
                raw.baseAddress!
                    .advanced(by: i * MemoryLayout<AudioBuffer>.size)
                    .assumingMemoryBound(to: AudioBuffer.self)
                    .pointee
            }
        }

        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0

        // 交错数据：直接复制
        if buffers.count == 1, let data = buffers[0].mData {
            let byteCount = Int(buffers[0].mDataByteSize)
            if isFloat && bytesPerSample == 4 {
                return Data(bytes: data, count: byteCount)
            }
            // 非 Float32，转为 Float32
            return convertToFloat32(data: data, byteCount: byteCount, bytesPerSample: bytesPerSample, isFloat: isFloat, channels: channels, interleaved: true)
        }

        // 非交错多 buffer：逐声道交错合并
        guard buffers.first?.mData != nil else { return nil }
        let samplesPerChannel = Int(buffers[0].mDataByteSize) / bytesPerSample
        var out = Data()
        out.reserveCapacity(samplesPerChannel * channels * 4)
        var floatBuf = [Float](repeating: 0, count: samplesPerChannel * channels)

        for f in 0..<samplesPerChannel {
            for c in 0..<buffers.count {
                guard let base = buffers[c].mData else { continue }
                let samplePtr = base.advanced(by: f * bytesPerSample)
                let v: Float
                if isFloat && bytesPerSample == 4 {
                    v = samplePtr.assumingMemoryBound(to: Float.self).pointee
                } else if bytesPerSample == 2 {
                    let i16 = samplePtr.assumingMemoryBound(to: Int16.self).pointee
                    v = Float(i16) / 32768.0
                } else {
                    continue
                }
                floatBuf[f * buffers.count + c] = v
            }
        }
        floatBuf.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    private func convertToFloat32(data: UnsafeMutableRawPointer, byteCount: Int, bytesPerSample: Int, isFloat: Bool, channels: Int, interleaved: Bool) -> Data {
        let sampleCount = byteCount / bytesPerSample
        var out = [Float](repeating: 0, count: sampleCount)
        if isFloat && bytesPerSample == 4 {
            // 已是 Float32 但交错标志不符，直接拷贝
            return Data(bytes: data, count: byteCount)
        }
        for i in 0..<sampleCount {
            let p = data.advanced(by: i * bytesPerSample)
            if bytesPerSample == 2 {
                out[i] = Float(p.assumingMemoryBound(to: Int16.self).pointee) / 32768.0
            } else if bytesPerSample == 4 && !isFloat {
                let i32 = p.assumingMemoryBound(to: Int32.self).pointee
                out[i] = Float(i32) / 2147483648.0
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}
