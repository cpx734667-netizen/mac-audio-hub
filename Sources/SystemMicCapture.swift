import Foundation
import AVFoundation
import CoreMedia

/// Captures an iPhone Continuity microphone through AVFoundation, which is the
/// same path macOS uses for "Continuity Camera" audio. It avoids forcing a
/// CoreAudio AUHAL device and works whether or not the iPhone is the system's
/// default input.
final class SystemMicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let continuityTransport: Int32 = 0x6363_7764 // 'ccwd'

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let callbackQueue = DispatchQueue(label: "com.airmic.systemmic.callback", qos: .userInteractive)
    private var running = false

    var onSamples: (([Float], Double) -> Void)?
    var onError: ((String) -> Void)?

    static func requestedPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func availableContinuityDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.filter { device in
            device.transportType == continuityTransport
                || device.localizedName.localizedCaseInsensitiveContains("iPhone")
                || device.localizedName.localizedCaseInsensitiveContains("iPad")
        }
    }

    static func device(forUID uid: String) -> AVCaptureDevice? {
        availableContinuityDevices().first(where: { $0.uniqueID == uid })
    }

    func start(device: AVCaptureDevice) throws {
        guard !running else { return }

        session.beginConfiguration()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw error
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(
                domain: "AirMic.SystemMic",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mac 无法接收这个 iPhone 麦克风（可能正被其他 App 使用）。"]
            )
        }
        session.addInput(input)

        // Do not request a converted format here. Continuity audio can reject
        // the AVFoundation audio converter, which silently stalls the stream.
        // Let AVFoundation deliver the device's native PCM and convert below.
        output.setSampleBufferDelegate(self, queue: callbackQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(
                domain: "AirMic.SystemMic",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 iPhone 麦克风音频输出。"]
            )
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        guard session.isRunning else {
            throw NSError(
                domain: "AirMic.SystemMic",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "iPhone 麦克风没有开始传输，请解锁 iPhone 后重试。"]
            )
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        session.stopRunning()
        if let input = session.inputs.first {
            session.removeInput(input)
        }
        session.removeOutput(output)
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        let bufferList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, bufferList.count > 0,
              let data = bufferList[0].mData else { return }

        var mono = [Float](repeating: 0, count: frames)
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0

        if bufferList.count == 1 && !nonInterleaved && channels > 1 {
            // One interleaved buffer: average channels for every frame.
            if isFloat {
                let pointer = data.bindMemory(to: Float.self, capacity: frames * channels)
                for index in 0..<frames {
                    var value: Float = 0
                    for channel in 0..<channels { value += pointer[index * channels + channel] }
                    mono[index] = value / Float(channels)
                }
            } else if asbd.mBitsPerChannel == 16 {
                let pointer = data.bindMemory(to: Int16.self, capacity: frames * channels)
                for index in 0..<frames {
                    var value: Float = 0
                    for channel in 0..<channels { value += Float(Int16(littleEndian: pointer[index * channels + channel])) / 32768.0 }
                    mono[index] = value / Float(channels)
                }
            } else if asbd.mBitsPerChannel == 32 {
                let pointer = data.bindMemory(to: Int32.self, capacity: frames * channels)
                for index in 0..<frames {
                    var value: Float = 0
                    for channel in 0..<channels { value += Float(Int32(littleEndian: pointer[index * channels + channel])) / 2_147_483_648.0 }
                    mono[index] = value / Float(channels)
                }
            } else {
                return
            }
        } else {
            let channelCount = max(1, min(bufferList.count, channels))
            if isFloat {
                for channel in 0..<channelCount {
                    guard let pointer = bufferList[channel].mData?.bindMemory(to: Float.self, capacity: frames) else { continue }
                    for index in 0..<frames { mono[index] += pointer[index] / Float(channelCount) }
                }
            } else if asbd.mBitsPerChannel == 16 {
                for channel in 0..<channelCount {
                    guard let pointer = bufferList[channel].mData?.bindMemory(to: Int16.self, capacity: frames) else { continue }
                    for index in 0..<frames { mono[index] += Float(Int16(littleEndian: pointer[index])) / 32768.0 / Float(channelCount) }
                }
            } else if asbd.mBitsPerChannel == 32 {
                for channel in 0..<channelCount {
                    guard let pointer = bufferList[channel].mData?.bindMemory(to: Int32.self, capacity: frames) else { continue }
                    for index in 0..<frames { mono[index] += Float(Int32(littleEndian: pointer[index])) / 2_147_483_648.0 / Float(channelCount) }
                }
            } else {
                return
            }
        }

        let result = mono
        callbackQueue.async { [weak self] in
            self?.onSamples?(result, sampleRate)
        }
    }
}
