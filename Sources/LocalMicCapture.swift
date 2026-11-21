import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures the Mac's default input device. It runs on its own AVAudioEngine so
/// enabling local monitoring never disturbs the phone-output engine.
final class LocalMicCapture {
    private let engine = AVAudioEngine()
    private var running = false
    private let callbackQueue = DispatchQueue(label: "com.airmic.localmic.callback", qos: .userInteractive)

    var onSamples: (([Float], Double) -> Void)?
    var onError: ((String) -> Void)?

    var isRunning: Bool { running }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
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

    func start(deviceID: AudioDeviceID? = nil) throws {
        guard !running else { return }
        let input = engine.inputNode
        if let deviceID {
            guard let audioUnit = input.audioUnit else {
                throw NSError(
                    domain: "AirMic.LocalMic",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "无法初始化音频输入单元。"]
                )
            }
            var device = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw NSError(
                    domain: "AirMic.LocalMic",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "无法连接这个音频输入设备（iPhone 可能已断开）。"]
                )
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(
                domain: "AirMic.LocalMic",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "没有找到可用的 Mac 麦克风。"]
            )
        }

        input.installTap(onBus: 0, bufferSize: 128, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    deinit {
        if running {
            engine.stop()
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frames)
        if buffer.format.isInterleaved {
            let data = channels[0]
            for frame in 0..<frames {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += data[frame * channelCount + channel]
                }
                mono[frame] = value / Float(channelCount)
            }
        } else {
            for frame in 0..<frames {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += channels[channel][frame]
                }
                mono[frame] = value / Float(channelCount)
            }
        }

        let rate = buffer.format.sampleRate
        callbackQueue.async { [weak self] in
            self?.onSamples?(mono, rate)
        }
    }
}
