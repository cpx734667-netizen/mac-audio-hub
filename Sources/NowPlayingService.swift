import Foundation
import AppKit

struct NowPlayingTrack: Equatable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsed: Double
    let isPlaying: Bool

    var subtitle: String {
        if artist.isEmpty { return album }
        if album.isEmpty { return artist }
        return "\(artist) · \(album)"
    }
}

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var isAvailable = false
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private let helperQueue = DispatchQueue(label: "com.airmic.nowplaying", qos: .utility)
    private var lastTrackID = ""

    private var helperURL: URL? {
        Bundle.main.url(forResource: "nowplaying-cli", withExtension: nil)
    }

    func start() {
        guard timer == nil else { return }
        isAvailable = helperURL != nil
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing, let helperURL else { return }
        isRefreshing = true
        helperQueue.async { [weak self] in
            let data = Self.run(helperURL, arguments: ["get"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.apply(data)
            }
        }
    }

    func send(_ command: String) {
        guard let helperURL else { return }
        helperQueue.async {
            _ = Self.run(helperURL, arguments: [command])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func apply(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String, !title.isEmpty else {
            track = nil
            lastTrackID = ""
            return
        }
        let artist = (object["artist"] as? String) ?? ""
        let album = (object["album"] as? String) ?? ""
        let duration = Self.number(object["duration"])
        let elapsed = Self.number(object["elapsedTime"])
        let isPlaying = (object["isPlaying"] as? Bool) ?? (Self.number(object["playbackRate"]) > 0)
        let id = "\(title)|\(artist)|\(Int(duration.rounded()))"
        track = NowPlayingTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: elapsed,
            isPlaying: isPlaying
        )
        lastTrackID = id
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let string = value as? String, let double = Double(string) { return double }
        return 0
    }

    private static func run(_ url: URL, arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return Data()
        }
        process.waitUntilExit()
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
