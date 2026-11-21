import Foundation

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var status = "先在音乐平台播放歌曲"
    @Published private(set) var source = ""
    @Published var offset: Double = 0

    private var cache: [String: [LyricLine]] = [:]
    private var currentTrackID = ""
    private var requestToken = UUID()

    func load(for track: NowPlayingTrack) {
        guard track.id != currentTrackID else { return }
        currentTrackID = track.id
        if let cached = cache[track.id] {
            lines = cached
            status = "歌词已同步"
            source = "LRCLIB"
            return
        }
        lines = []
        status = "正在匹配歌词…"
        source = ""
        let token = UUID()
        requestToken = token
        Task {
            let result = await Self.fetch(track: track)
            guard token == requestToken else { return }
            switch result {
            case .success(let lyrics):
                guard let text = lyrics, !text.isEmpty else {
                    status = "没有匹配到歌词，可手动载入 LRC"
                    return
                }
                let parsed = Self.parseLRC(text)
                if parsed.isEmpty {
                    lines = Self.plainLines(text)
                    status = "纯文本歌词（无法自动滚动）"
                } else {
                    lines = parsed
                    status = "歌词已同步"
                }
                cache[track.id] = lines
                source = "LRCLIB"
            case .failure:
                status = "歌词服务不可用，可手动载入 LRC"
            }
        }
    }

    func search(title: String, artist: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            status = "请输入歌名"
            return
        }
        let token = UUID()
        requestToken = token
        status = "正在搜索歌词…"
        Task {
            let result = await Self.searchRemote(title: trimmedTitle, artist: artist)
            guard token == requestToken else { return }
            switch result {
            case .success(let text):
                guard let text, !text.isEmpty else {
                    status = "没有找到歌词"
                    return
                }
                let parsed = Self.parseLRC(text)
                lines = parsed.isEmpty ? Self.plainLines(text) : parsed
                status = parsed.isEmpty ? "纯文本歌词（无法自动滚动）" : "歌词已同步"
                source = "LRCLIB 搜索"
            case .failure:
                status = "歌词服务不可用"
            }
        }
    }

    func loadManualLRC(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            status = "无法读取 LRC 文件"
            return
        }
        let parsed = Self.parseLRC(text)
        lines = parsed.isEmpty ? Self.plainLines(text) : parsed
        status = parsed.isEmpty ? "纯文本歌词（无法自动滚动）" : "已载入本地 LRC"
        source = url.lastPathComponent
        offset = 0
    }

    func currentIndex(at elapsed: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        let target = elapsed + offset
        var low = 0
        var high = lines.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= target {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    // MARK: - Networking

    private enum FetchResult {
        case success(String?)
        case failure
    }

    private static func fetch(track: NowPlayingTrack) async -> FetchResult {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: track.duration > 0 ? String(Int(track.duration.rounded())) : nil)
        ].filter { $0.value != nil }
        guard let url = components?.url else { return .failure }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failure }
            if http.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = object["syncedLyrics"] as? String {
                return .success(text)
            }
            return await searchRemote(title: track.title, artist: track.artist)
        } catch {
            return .failure
        }
    }

    private static func searchRemote(title: String, artist: String) async -> FetchResult {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return .failure }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .failure }
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failure
            }
            for object in array {
                if let text = object["syncedLyrics"] as? String, !text.isEmpty {
                    return .success(text)
                }
            }
            return .success(nil)
        } catch {
            return .failure
        }
    }

    // MARK: - LRC

    static func parseLRC(_ text: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{1,2}(?:\.\d{1,3})?)\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [LyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }
            for match in matches {
                guard match.numberOfRanges >= 4,
                      let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let textRange = Range(match.range(at: 3), in: rawLine),
                      let minutes = Double(rawLine[minuteRange]),
                      let seconds = Double(rawLine[secondRange]) else { continue }
                let content = String(rawLine[textRange]).trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { continue }
                result.append(LyricLine(time: minutes * 60 + seconds, text: content))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    static func plainLines(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(time: -Double($0.offset), text: $0.element) }
    }
}
