import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class KaraokeUIState: ObservableObject {
    @Published var manualTitle = ""
    @Published var manualArtist = ""
    @Published var showManualSearch = false
    @Published var clockElapsed: Double = 0
    @Published var clockRunning = false

    private var timer: Timer?
    private var startedAt: Date?
    private var base: Double = 0

    func toggleClock() {
        if clockRunning { pauseClock() } else { startClock() }
    }

    func resetClock() {
        timer?.invalidate()
        timer = nil
        clockRunning = false
        startedAt = nil
        base = 0
        clockElapsed = 0
    }

    private func startClock() {
        guard !clockRunning else { return }
        startedAt = Date()
        base = clockElapsed
        clockRunning = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                self.clockElapsed = self.base + Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pauseClock() {
        timer?.invalidate()
        timer = nil
        clockRunning = false
        startedAt = nil
    }

    deinit {
        timer?.invalidate()
    }
}

struct KaraokeWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var ui: KaraokeUIState
    @Binding var mode: HubMode
    let width: CGFloat

    private var wide: Bool { width >= 980 }

    private var elapsed: Double {
        nowPlaying.track?.elapsed ?? ui.clockElapsed
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            if wide {
                HStack(alignment: .top, spacing: 16) {
                    platformCard
                        .frame(width: 390)
                        .frame(height: 390)
                    lyricsCard
                        .frame(maxWidth: .infinity)
                        .frame(height: 390)
                }
            } else {
                VStack(spacing: 16) {
                    platformCard.frame(height: 390)
                    lyricsCard.frame(height: 420)
                }
            }

            lowLatencyStrip
        }
        .onAppear {
            nowPlaying.start()
            if let track = nowPlaying.track {
                lyrics.load(for: track)
            }
        }
        .onDisappear {
            nowPlaying.stop()
        }
        .onChange(of: nowPlaying.track?.id) { _, _ in
            if let track = nowPlaying.track {
                lyrics.load(for: track)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "music.mic")
                        .font(.system(size: 11, weight: .bold))
                    Text("K歌模式")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Color.airMint)

                Text("平台放伴奏，手机当麦克风")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("音乐在网易云 / QQ 音乐 / 酷狗里播放；本 App 负责人声监听，并尽量同步显示平台当前歌曲歌词。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.airMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isLive ? Color.airMint : Color.airWarning)
                        .frame(width: 5, height: 5)
                    Text(model.isLive ? "人声监听中 · \(model.latencyMilliseconds) ms" : "等待手机麦克风")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.isLive ? Color.airMint : Color.airWarning)
                }
                Button {
                    model.selectLowLatencyOutput()
                } label: {
                    Label(model.isKaraokeOutputUnified ? "统一输出" : "统一音乐与人声", systemImage: "arrow.triangle.merge")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(KaraokeSmallButtonStyle())
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Platform

    private var platformCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("平台伴奏 · 当前播放")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
            }
            .foregroundStyle(Color.airIndigo)

            if let track = nowPlaying.track {
                Text(track.title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.top, 9)
                Text(track.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.airMuted)
                    .lineLimit(1)
                    .padding(.top, 2)
                if track.duration > 0 {
                    ProgressView(value: min(max(track.elapsed, 0), track.duration), total: track.duration)
                        .tint(Color.airIndigo)
                        .padding(.top, 9)
                    HStack {
                        Text(Self.time(track.elapsed))
                        Spacer()
                        Text(Self.time(track.duration))
                    }
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                }
            } else {
                Text("等待音乐平台播放")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 9)
                Text("先在下面打开网易云、QQ 音乐或酷狗，并播放一首歌。")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.airMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }

            HStack(spacing: 10) {
                Button { nowPlaying.send("previous") } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(nowPlaying.track == nil)

                Button {
                    nowPlaying.send((nowPlaying.track?.isPlaying ?? false) ? "pause" : "play")
                } label: {
                    Image(systemName: (nowPlaying.track?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.airIndigo.opacity(0.20)))
                }
                .disabled(nowPlaying.track == nil)

                Button { nowPlaying.send("next") } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(nowPlaying.track == nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.top, 10)

            Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 10)

            Text("打开音乐平台")
                .font(.system(size: 8.8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))
                .padding(.bottom, 7)

            HStack(spacing: 7) {
                platformButton("网易云", bundle: "com.netease.163music", scheme: "orpheus://")
                platformButton("QQ 音乐", bundle: "com.tencent.QQMusicMac", scheme: "qqmusicmac://")
                platformButton("酷狗", bundle: "com.kugou.mac.Music", scheme: "kugouURL://")
            }

            Spacer(minLength: 8)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.airWarning.opacity(0.8))
                Text("原唱/伴奏请在平台播放器内切换；平台不向第三方开放原唱接口。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KaraokeCardBackground())
    }

    private func platformButton(_ title: String, bundle: String, scheme: String) -> some View {
        Button {
            openPlatform(bundleID: bundle, scheme: scheme)
        } label: {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func openPlatform(bundleID: String, scheme: String) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let url = URL(string: scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lyrics

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步歌词")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(Color.airMint)
                    Text(lyrics.status)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
                HStack(spacing: 4) {
                    Button("-0.5s") { lyrics.offset -= 0.5 }
                    Text(String(format: "%+.1fs", lyrics.offset))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 46)
                    Button("+0.5s") { lyrics.offset += 0.5 }
                }
                .buttonStyle(KaraokeTinyButtonStyle())
            }

            HStack(spacing: 6) {
                Button {
                    ui.toggleClock()
                } label: {
                    Label(ui.clockRunning ? "暂停歌词" : "开始歌词", systemImage: ui.clockRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(KaraokeTinyButtonStyle())
                Button("歌词归零") { ui.resetClock() }
                    .buttonStyle(KaraokeTinyButtonStyle())
                Text(Self.time(ui.clockElapsed))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                Spacer()
                Text(nowPlaying.track == nil ? "平台未提供播放位置时，可手动对歌词" : "跟随平台播放位置")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.24))
            }
            .padding(.top, 7)

            Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 9)

            if lyrics.lines.isEmpty {
                emptyLyrics
            } else {
                lyricLines
            }

            Spacer(minLength: 6)

            HStack(spacing: 8) {
                Button {
                    ui.showManualSearch.toggle()
                } label: {
                    Label("手动搜歌词", systemImage: "magnifyingglass")
                }
                .buttonStyle(KaraokeSmallButtonStyle())

                Button {
                    chooseLRC()
                } label: {
                    Label("载入 LRC", systemImage: "doc.text")
                }
                .buttonStyle(KaraokeSmallButtonStyle())

                Spacer()
                if !lyrics.source.isEmpty {
                    Text(lyrics.source)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .padding(.top, 8)

            if ui.showManualSearch {
                HStack(spacing: 6) {
                    TextField("歌名", text: $ui.manualTitle)
                    TextField("歌手", text: $ui.manualArtist)
                    Button("搜索") {
                        lyrics.search(title: ui.manualTitle, artist: ui.manualArtist)
                    }
                    .buttonStyle(KaraokeTinyButtonStyle())
                }
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .padding(.top, 7)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KaraokeCardBackground())
    }

    private var emptyLyrics: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.16))
            Text(nowPlaying.track == nil ? "播放平台歌曲后自动匹配歌词" : "没有匹配到歌词")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text("也可以手动搜索歌名，或载入同名 .lrc 文件")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lyricLines: some View {
        let index = lyrics.lines.isEmpty ? -1 : lyrics.currentIndex(at: elapsed)
        let start = max(0, index - 2)
        let end = min(lyrics.lines.count - 1, index + 4)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 9) {
                    if start > 0 {
                        Color.clear.frame(height: 1).id("lyrics-top")
                    }
                    ForEach(start...end, id: \.self) { i in
                        let line = lyrics.lines[i]
                        Text(line.text)
                            .font(.system(size: i == index ? 21 : 12.5, weight: i == index ? .bold : .medium, design: .rounded))
                            .foregroundStyle(i == index ? Color.airMint : .white.opacity(i < index ? 0.25 : 0.45))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(i)
                            .animation(.easeOut(duration: 0.2), value: index)
                    }
                }
                .padding(.vertical, 3)
            }
            .onChange(of: index) { _, newValue in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func chooseLRC() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择与歌曲同名的 .lrc 歌词文件"
        if panel.runModal() == .OK, let url = panel.url {
            lyrics.loadManualLRC(at: url)
        }
    }

    // MARK: - Mic strip

    private var micSummary: String {
        let source = model.systemMicEnabled
            ? "\(model.systemMicDeviceName)（系统）"
            : "\(model.phoneCount) 路手机"
        return "\(source) · \(model.latencyMilliseconds) ms · 人声：\(model.outputDeviceName)"
    }

    private var lowLatencyStrip: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(model.isLive ? Color.airMint.opacity(0.12) : Color.white.opacity(0.05))
                    Image(systemName: model.localMicEnabled ? "mic.fill" : "iphone.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.isLive ? Color.airMint : Color.airMuted)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isLive ? "人声正在监听" : "还没有手机麦克风")
                        .font(.system(size: 10.8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(model.isLive ? micSummary : "先在手机麦克风页扫码连接")
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                    if !model.isKaraokeOutputUnified {
                        Text("音乐在：\(model.systemDefaultOutputName) · 点右侧「统一输出」让两者同音箱")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.airWarning.opacity(0.85))
                            .lineLimit(1)
                    } else {
                        Text("音乐与人声已统一输出")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Color.airMint.opacity(0.7))
                    }
                }
            }

            if let url = model.serverURL, let qr = QRCodeGenerator.makeImage(for: url.absoluteString, pixelSize: 6) {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 46, height: 46)
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white))
            }

            Spacer()

            if !model.systemInputDevices.isEmpty {
                Button {
                    model.setSystemMic(!model.systemMicEnabled)
                } label: {
                    Label(model.systemMicEnabled ? "iPhone 麦克风已开" : "iPhone 麦克风", systemImage: "iphone")
                }
                .buttonStyle(KaraokeSmallButtonStyle())
            }

            Button {
                mode = .mic
            } label: {
                Label(model.isLive ? "麦克风设置" : "连接手机麦克风", systemImage: "iphone")
            }
            .buttonStyle(KaraokeSmallButtonStyle())

            Button {
                model.selectLowLatencyOutput()
            } label: {
                Label("统一输出", systemImage: "arrow.triangle.merge")
            }
            .buttonStyle(KaraokeSmallButtonStyle())

            Button {
                model.testTone()
            } label: {
                Label("测试输出", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(KaraokeSmallButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(KaraokeCardBackground())
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Chrome

private struct KaraokeCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.062), Color.white.opacity(0.032)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }
}

private struct KaraokeSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(configuration.isPressed ? 0.035 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

private struct KaraokeTinyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8.8, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.45 : 0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.045)))
    }
}
