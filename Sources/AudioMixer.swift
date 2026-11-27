import Foundation
import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio

struct MixSourceLevel {
    let id: UUID
    let level: Float
    let queueMilliseconds: Double
    let muted: Bool
}

/// Mixes any number of mono microphone streams into one low-latency stereo
/// output. Every source is resampled to 48 kHz and gets its own adaptive queue;
/// a 5 ms mix tick keeps the output buffer deliberately short.
final class AudioMixer {
    struct Snapshot {
        var bufferMilliseconds: Double = 0
        var pendingMilliseconds: Double = 0
        var scheduledAheadMilliseconds: Double = 0
        var queueMilliseconds: Double = 0
        var underruns: Int = 0
        var level: Float = 0
        var sampleRate: Double = 48_000
        var outputLatencyMilliseconds: Double = 0
        var engineRunning: Bool = false
        var playerRunning: Bool = false
        var targetAheadMilliseconds: Double = 0
        var sources: [MixSourceLevel] = []
        var silentChunks: Int = 0
        var droppedSourceFrames: Int = 0
    }

    static let sampleRate: Double = 48_000
    private static let chunkFrames: AVAudioFrameCount = 240 // 5 ms

    private final class Source {
        let id: UUID
        var name: String
        var samples: [Float] = []
        var readIndex = 0
        var level: Float = 0
        var lastDataAt = Date.distantPast
        var muted = false
        var primed = false
        var prebufferFrames: Int
        var maxQueueFrames: Int
        var droppedFrames = 0
        var lastSample: Float = 0
        var converter: AVAudioConverter?
        var converterInputRate: Double = 0

        init(id: UUID, name: String, prebufferFrames: Int, maxQueueFrames: Int) {
            self.id = id
            self.name = name
            self.prebufferFrames = prebufferFrames
            self.maxQueueFrames = maxQueueFrames
        }

        var available: Int { samples.count - readIndex }

        var queueMilliseconds: Double {
            Double(available) / AudioMixer.sampleRate * 1000.0
        }

        func trim(maxFrames: Int) {
            guard available > maxFrames else { return }
            let dropped = available - maxFrames
            droppedFrames += dropped
            readIndex += dropped
            compactIfNeeded()
        }

        /// Returns a full-size chunk even when the network delivered a partial
        /// frame. Missing samples hold the last received sample instead of
        /// inserting a hard zero, which used to produce a click every time the
        /// queue landed just under 5 ms.
        func takeChunk(_ count: Int) -> [Float]? {
            guard primed else { return nil }
            let take = min(count, available)
            var chunk = [Float](repeating: lastSample, count: count)
            if take > 0 {
                let start = readIndex
                for index in 0..<take {
                    chunk[index] = samples[start + index]
                }
                lastSample = chunk[take - 1]
                readIndex += take
                compactIfNeeded()
            }
            return chunk
        }

        func append(_ input: [Float], rate: Double) {
            guard !input.isEmpty else { return }
            lastDataAt = Date()
            var sumSquares: Double = 0
            var peak: Float = 0
            for value in input {
                sumSquares += Double(value) * Double(value)
                peak = max(peak, abs(value))
            }
            let rms = Float(sqrt(sumSquares / Double(input.count)))
            let instant = max(rms * 1.8, peak * 0.55)
            level = max(instant, level * 0.74)

            if abs(rate - AudioMixer.sampleRate) < 1 {
                samples.append(contentsOf: input)
            } else {
                samples.append(contentsOf: resample(input, from: rate))
            }
            trim(maxFrames: maxQueueFrames)
        }

        func decayLevel(now: Date) {
            if now.timeIntervalSince(lastDataAt) > 0.10 {
                level *= 0.86
                if level < 0.002 { level = 0 }
            }
        }

        private func compactIfNeeded() {
            if readIndex > 8_192 && readIndex > samples.count / 2 {
                samples.removeFirst(readIndex)
                readIndex = 0
            }
        }

        private func resample(_ input: [Float], from rate: Double) -> [Float] {
            guard let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: 1,
                interleaved: false
            ), let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioMixer.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                return input
            }

            if converter == nil || abs(converterInputRate - rate) > 0.5 {
                let newConverter = AVAudioConverter(from: inFormat, to: outFormat)
                newConverter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter = newConverter
                converterInputRate = rate
            }
            guard let converter else { return input }

            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat,
                frameCapacity: AVAudioFrameCount(input.count)
            ) else { return input }
            inputBuffer.frameLength = AVAudioFrameCount(input.count)
            if let destination = inputBuffer.floatChannelData?[0] {
                for index in 0..<input.count { destination[index] = input[index] }
            }

            let capacity = AVAudioFrameCount(
                (Double(input.count) * AudioMixer.sampleRate / rate).rounded(.up)
            ) + 64
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                return input
            }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if status == .error || conversionError != nil || outputBuffer.frameLength == 0 {
                return linearResample(input, from: rate)
            }
            guard let source = outputBuffer.floatChannelData?[0] else {
                return linearResample(input, from: rate)
            }
            return Array(UnsafeBufferPointer(start: source, count: Int(outputBuffer.frameLength)))
        }

        private func linearResample(_ input: [Float], from rate: Double) -> [Float] {
            let ratio = AudioMixer.sampleRate / rate
            let count = max(1, Int((Double(input.count) * ratio).rounded(.down)))
            var output = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let position = Double(index) / ratio
                let lower = min(input.count - 1, Int(position))
                let upper = min(input.count - 1, lower + 1)
                let fraction = Float(position - Double(lower))
                output[index] = input[lower] * (1 - fraction) + input[upper] * fraction
            }
            return output
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let testPlayer = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.airmic.mixer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var sources: [UUID: Source] = [:]
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var scheduledFrames: AVAudioFramePosition = 0
    private var playerRunning = false
    private var underruns = 0
    private var silentChunks = 0
    private var aggregateLevel: Float = 0
    private var volume: Float = 0.9
    private var dcPreviousInput: Float = 0
    private var dcPreviousOutput: Float = 0
    private var outputFormat: AVAudioFormat?
    private var selectedOutputDeviceID: AudioDeviceID?
    private var engineError: String?
    private var reconfiguring = false

    private let startSeconds = 0.015
    private let initialAheadSeconds = 0.020
    private let maximumAheadSeconds = 0.070
    private var targetAheadSeconds = 0.020

    var onError: ((String) -> Void)?

    init(outputDeviceID: AudioDeviceID?) {
        engine.attach(player)
        engine.attach(testPlayer)
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: AudioMixer.sampleRate, channels: 2)
        if let outputFormat {
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            engine.connect(testPlayer, to: engine.mainMixerNode, format: outputFormat)
        }
        engine.mainMixerNode.outputVolume = volume
        selectedOutputDeviceID = outputDeviceID
        if let outputDeviceID {
            applyOutputDeviceLocked(outputDeviceID)
        }
        engine.prepare()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(2), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restoreAfterConfigurationChange() }
        }
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Public API

    func addSource(
        id: UUID,
        name: String,
        prebufferMilliseconds: Double = 20,
        maxQueueMilliseconds: Double = 60
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let frames = max(
                Int(AudioMixer.sampleRate * 0.005),
                Int(AudioMixer.sampleRate * prebufferMilliseconds / 1000.0)
            )
            let maxQueue = max(frames, Int(AudioMixer.sampleRate * maxQueueMilliseconds / 1000.0))
            if let existing = self.sources[id] {
                existing.name = name
                existing.prebufferFrames = frames
                existing.maxQueueFrames = maxQueue
            } else {
                self.sources[id] = Source(
                    id: id,
                    name: name,
                    prebufferFrames: frames,
                    maxQueueFrames: maxQueue
                )
            }
            if !self.engine.isRunning {
                self.startEngineLocked()
            }
        }
    }

    func removeSource(id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sources.removeValue(forKey: id)
            if self.sources.isEmpty {
                self.stopPlaybackLocked()
            }
        }
    }

    func setMuted(id: UUID, muted: Bool) {
        queue.async { [weak self] in
            self?.sources[id]?.muted = muted
        }
    }

    func enqueue(pcm: Data, sampleRate: Double, sourceID: UUID) {
        guard sampleRate > 8_000, pcm.count >= 2 else { return }
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                samples[index] = Float(Int16(littleEndian: values[index])) / 32768.0
            }
        }
        enqueue(samples: samples, sampleRate: sampleRate, sourceID: sourceID)
    }

    func enqueue(samples: [Float], sampleRate: Double, sourceID: UUID) {
        guard !samples.isEmpty, sampleRate > 8_000 else { return }
        queue.async { [weak self] in
            guard let self, let source = self.sources[sourceID] else { return }
            source.append(samples, rate: sampleRate)
            if !self.engine.isRunning {
                self.startEngineLocked()
            }
        }
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        queue.async { [weak self] in
            guard let self else { return }
            self.volume = clamped
            self.engine.mainMixerNode.outputVolume = clamped
        }
    }

    func setOutputDevice(_ id: AudioDeviceID) {
        queue.async { [weak self] in
            guard let self else { return }
            let shouldRestart = !self.sources.isEmpty
            self.stopPlaybackLocked()
            self.engine.stop()
            self.selectedOutputDeviceID = id
            self.reconfiguring = true
            self.applyOutputDeviceLocked(id)
            self.reconnectPlayerLocked()
            self.reconfiguring = false
            if shouldRestart {
                self.startEngineLocked()
            }
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.stopPlaybackLocked()
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            let rate = AudioMixer.sampleRate
            let aheadFrames = scheduledAheadLocked()
            let sourceSnapshots = sources.values.map {
                MixSourceLevel(
                    id: $0.id,
                    level: $0.level,
                    queueMilliseconds: $0.queueMilliseconds,
                    muted: $0.muted
                )
            }
            let maxSourceQueue = sourceSnapshots.map(\.queueMilliseconds).max() ?? 0
            let pendingMs = Double(pendingFrames) / rate * 1000.0
            let aheadMs = Double(aheadFrames) / rate * 1000.0
            let outputLatency = outputLatencyMillisecondsLocked()
            let queue = pendingMs + aheadMs + maxSourceQueue
            return Snapshot(
                bufferMilliseconds: queue + outputLatency,
                pendingMilliseconds: pendingMs,
                scheduledAheadMilliseconds: aheadMs,
                queueMilliseconds: queue,
                underruns: underruns,
                level: aggregateLevel,
                sampleRate: rate,
                outputLatencyMilliseconds: outputLatency,
                engineRunning: engine.isRunning,
                playerRunning: playerRunning,
                targetAheadMilliseconds: targetAheadSeconds * 1000,
                sources: sourceSnapshots,
                silentChunks: silentChunks,
                droppedSourceFrames: sources.values.reduce(0) { $0 + $1.droppedFrames }
            )
        }
    }

    func playTestTone() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.engine.isRunning {
                self.startEngineLocked()
            }
            guard self.engine.isRunning, let format = self.outputFormat else { return }
            let duration = 0.65
            let frameCount = AVAudioFrameCount(AudioMixer.sampleRate * duration)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            guard let channels = buffer.floatChannelData else { return }
            // A soft 660 Hz chime with short fades. It is scheduled on the same
            // output device as the microphone mix, so "测试声音" verifies the
            // currently selected speaker rather than the system default.
            for index in 0..<Int(frameCount) {
                let t = Double(index) / AudioMixer.sampleRate
                let envelope = min(1.0, t / 0.02) * min(1.0, (duration - t) / 0.12)
                let value = Float(sin(2 * Double.pi * 660 * t) * 0.28 * envelope)
                channels[0][index] = value
                channels[1][index] = value
            }
            self.testPlayer.stop()
            self.testPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            self.testPlayer.play()
        }
    }

    // MARK: - Audio graph

    private func applyOutputDeviceLocked(_ id: AudioDeviceID) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            report("无法切换到所选输出设备（错误 \(status)），将继续使用系统默认输出。")
        }
    }

    private func reconnectPlayerLocked() {
        guard let outputFormat else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
    }

    private func startEngineLocked() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            engineError = nil
        } catch {
            report("无法启动 Mac 音频输出：\(error.localizedDescription)")
        }
    }

    private func restoreAfterConfigurationChange() {
        guard !reconfiguring, !sources.isEmpty else { return }
        stopPlaybackLocked()
        reconnectPlayerLocked()
        startEngineLocked()
    }

    private func report(_ message: String) {
        if engineError == message { return }
        engineError = message
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    // MARK: - Mixing and scheduling

    private func tick() {
        guard !sources.isEmpty || playerRunning else { return }
        if !engine.isRunning {
            startEngineLocked()
        }
        guard engine.isRunning else { return }

        let now = Date()
        for source in sources.values {
            source.decayLevel(now: now)
            if source.available >= source.prebufferFrames {
                source.primed = true
            }
            if source.available == 0, now.timeIntervalSince(source.lastDataAt) > 0.20 {
                source.primed = false
            }
        }

        aggregateLevel = max(aggregateLevel * 0.90, sources.values.map(\.level).max() ?? 0)

        let hasPrimed = sources.values.contains { $0.primed && !$0.muted }
        if !playerRunning && !hasPrimed {
            return
        }

        let targetFrames = AVAudioFramePosition(
            AudioMixer.sampleRate * (playerRunning ? targetAheadSeconds : startSeconds)
        )
        var guardCounter = 0
        while pendingFrames + scheduledAheadLocked() < targetFrames + AVAudioFramePosition(Self.chunkFrames),
              guardCounter < 6 {
            mixChunkLocked()
            guardCounter += 1
            if !playerRunning && pendingFrames >= AVAudioFramePosition(AudioMixer.sampleRate * startSeconds) {
                break
            }
        }

        if !playerRunning {
            let startFrames = AVAudioFramePosition(AudioMixer.sampleRate * startSeconds)
            guard pendingFrames >= startFrames else { return }
            while !pending.isEmpty { scheduleNextLocked() }
            player.play()
            playerRunning = true
        }

        let maxAhead = AVAudioFramePosition(AudioMixer.sampleRate * targetAheadSeconds)
        while !pending.isEmpty && scheduledAheadLocked() < maxAhead {
            scheduleNextLocked()
        }
    }

    private func mixChunkLocked() {
        guard let format = outputFormat else { return }
        let frameCount = Int(Self.chunkFrames)
        let usable = sources.values.filter { $0.primed && !$0.muted }
        if usable.isEmpty {
            silentChunks += 1
        }
        let normalization = usable.isEmpty ? 0 : 1.0 / sqrt(Float(usable.count))
        var mixed = [Float](repeating: 0, count: frameCount)

        for source in usable {
            guard let chunk = source.takeChunk(frameCount) else { continue }
            for index in 0..<frameCount {
                mixed[index] += chunk[index] * normalization
            }
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else { return }
        buffer.frameLength = Self.chunkFrames
        guard let channels = buffer.floatChannelData else { return }
        var peak: Float = 0
        for index in 0..<frameCount {
            // Remove DC offset/thumps before limiting. A 0.995 one-pole
            // high-pass at 48 kHz is inaudible on voice but kills DC steps.
            let raw = mixed[index]
            let filtered = raw - dcPreviousInput + 0.995 * dcPreviousOutput
            dcPreviousInput = raw
            dcPreviousOutput = filtered

            // Soft-knee limiter: avoids hard clipping when two phones or the
            // local mic peak at the same time.
            let limited = Self.softLimit(filtered)
            let value = max(-1.0, min(1.0, limited)) * volume
            channels[0][index] = value
            channels[1][index] = value
            peak = max(peak, abs(value))
        }
        aggregateLevel = max(aggregateLevel, peak)
        pending.append(buffer)
        pendingFrames += AVAudioFramePosition(Self.chunkFrames)
    }

    private static func softLimit(_ value: Float) -> Float {
        let threshold: Float = 0.92
        let magnitude = abs(value)
        guard magnitude > threshold else { return value }
        let sign: Float = value < 0 ? -1 : 1
        let room = 1 - threshold
        let compressed = threshold + room * (1 - exp(-(magnitude - threshold) / room))
        return sign * compressed
    }

    private func scheduleNextLocked() {
        guard !pending.isEmpty else { return }
        let buffer = pending.removeFirst()
        pendingFrames -= AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
    }

    private func stopPlaybackLocked() {
        player.stop()
        testPlayer.stop()
        playerRunning = false
        pending.removeAll(keepingCapacity: true)
        pendingFrames = 0
        scheduledFrames = 0
        aggregateLevel = 0
        underruns = 0
        silentChunks = 0
        dcPreviousInput = 0
        dcPreviousOutput = 0
        targetAheadSeconds = initialAheadSeconds
    }

    private func renderedFramesLocked() -> AVAudioFramePosition {
        guard playerRunning,
              let renderTime = player.lastRenderTime,
              renderTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: renderTime) else {
            return 0
        }
        return max(0, playerTime.sampleTime)
    }

    private func scheduledAheadLocked() -> AVAudioFramePosition {
        guard playerRunning else { return 0 }
        return max(0, scheduledFrames - renderedFramesLocked())
    }

    private func outputLatencyMillisecondsLocked() -> Double {
        guard engine.isRunning else { return 0 }
        return max(0, engine.outputNode.presentationLatency * 1000.0)
    }
}
