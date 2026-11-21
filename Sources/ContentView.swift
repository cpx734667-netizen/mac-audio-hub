import SwiftUI
import AppKit

// MARK: - Palette

extension Color {
    static let airMint = Color(red: 0.36, green: 0.92, blue: 0.82)
    static let airTeal = Color(red: 0.16, green: 0.78, blue: 0.72)
    static let airIndigo = Color(red: 0.52, green: 0.56, blue: 0.97)
    static let airInk = Color(red: 0.035, green: 0.055, blue: 0.10)
    static let airMuted = Color(red: 0.58, green: 0.64, blue: 0.72)
    static let airWarning = Color(red: 1.0, green: 0.72, blue: 0.32)
}

final class HubUIState: ObservableObject {
    @Published var mode: HubMode

    init() {
        switch ProcessInfo.processInfo.environment["AIRMIC_HUB_MODE"] {
        case "karaoke": mode = .karaoke
        case "speaker": mode = .speaker
        default: mode = .mic
        }
    }
}

enum HubMode: String, CaseIterable, Identifiable {
    case mic
    case karaoke
    case speaker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mic: return "麦克风"
        case .karaoke: return "K歌"
        case .speaker: return "音箱"
        }
    }

    var icon: String {
        switch self {
        case .mic: return "mic.fill"
        case .karaoke: return "music.mic"
        case .speaker: return "hifispeaker.2.fill"
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var speaker = SpeakerRuntime()
    @StateObject private var nowPlaying = NowPlayingService()
    @StateObject private var lyrics = LyricsService()
    @StateObject private var karaokeUI = KaraokeUIState()
    @StateObject private var ui = HubUIState()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                BackgroundView()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        HeaderView(
                            mode: $ui.mode,
                            speakerModel: speaker.model,
                            speakerController: speaker.controller
                        )

                        Group {
                            switch ui.mode {
                            case .mic:
                                MicWorkspace(width: geo.size.width - 52)
                            case .karaoke:
                                KaraokeWorkspace(
                                    nowPlaying: nowPlaying,
                                    lyrics: lyrics,
                                    ui: karaokeUI,
                                    mode: $ui.mode,
                                    width: geo.size.width - 52
                                )
                            case .speaker:
                                SpeakerWorkspace(
                                    model: speaker.model,
                                    controller: speaker.controller,
                                    micLive: model.isLive,
                                    width: geo.size.width - 52
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        Spacer(minLength: 0)

                        FooterView(speakerModel: speaker.model)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 34)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(geo.size.height, 640), alignment: .top)
                }

                if let notice = model.notice {
                    NoticeBanner(text: notice)
                        .padding(.bottom, 34)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.notice)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .animation(.easeInOut(duration: 0.22), value: ui.mode)
    }
}

private struct MicWorkspace: View {
    @EnvironmentObject private var model: AppModel
    let width: CGFloat

    var body: some View {
        let wide = width >= 980
        VStack(spacing: 16) {
            if wide {
                HStack(alignment: .top, spacing: 18) {
                    QRPanel()
                        .frame(width: max(360, min(408, width * 0.41)))
                        .frame(height: 580)
                    StatusPanel()
                        .frame(maxWidth: .infinity)
                        .frame(height: 580)
                }
            } else {
                VStack(spacing: 16) {
                    QRPanel()
                        .frame(maxWidth: .infinity)
                        .frame(height: 580)
                    StatusPanel()
                        .frame(maxWidth: .infinity)
                        .frame(height: 580)
                }
            }

            SourceStrip()
                .frame(height: 100)
        }
    }
}

// MARK: - Background

private struct BackgroundView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.038, blue: 0.072),
                    Color(red: 0.045, green: 0.065, blue: 0.115),
                    Color(red: 0.025, green: 0.035, blue: 0.065)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(RadialGradient(colors: [Color.airMint.opacity(0.13), .clear], center: .center, startRadius: 0, endRadius: 330))
                .frame(width: 660, height: 660)
                .offset(x: -430, y: -300)
                .blur(radius: 18)

            Circle()
                .fill(RadialGradient(colors: [Color.airIndigo.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 360))
                .frame(width: 720, height: 720)
                .offset(x: 470, y: 330)
                .blur(radius: 22)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.025), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var mode: HubMode
    @ObservedObject var speakerModel: SpeakerModel
    let speakerController: AppController

    private var speakerURL: String {
        if let ip = speakerModel.ipAddresses.first {
            return "http://\(ip):\(speakerModel.port)/"
        }
        return "http://\(speakerModel.port)/"
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.airMint, Color.airTeal, Color.airIndigo.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.airMint.opacity(0.28), radius: 12, x: 0, y: 4)
                Image(systemName: "waveform")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.airInk)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("AirMic Hub")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("双向音频")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.airMint.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.airMint.opacity(0.10)))
                        .overlay(Capsule().stroke(Color.airMint.opacity(0.18), lineWidth: 1))
                }
                Text("手机麦克风 × Mac 系统音频，两个服务同时运行")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.airMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HubModeSwitcher(mode: $mode, micLive: model.isLive, speakerModel: speakerModel)

            switch mode {
            case .mic:
                MicStatusPill()
            case .karaoke:
                KaraokeStatusPill()
            case .speaker:
                SpeakerStatusPill(model: speakerModel)
            }

            Menu {
                Button {
                    model.refreshNetwork()
                } label: {
                    Label("刷新麦克风二维码", systemImage: "arrow.clockwise")
                }
                Button {
                    model.testTone()
                } label: {
                    Label("测试当前输出", systemImage: "speaker.wave.2.fill")
                }
                Button {
                    model.openSoundSettings()
                } label: {
                    Label("打开声音设置", systemImage: "slider.horizontal.3")
                }
                Divider()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(speakerURL, forType: .string)
                } label: {
                    Label("复制音箱播放地址", systemImage: "doc.on.doc")
                }
                Button {
                    speakerController.checkScreenPermission()
                } label: {
                    Label("检测屏幕录制权限", systemImage: "checkmark.shield")
                }
                Button {
                    speakerController.openScreenRecordingSettings()
                } label: {
                    Label("打开屏幕录制设置", systemImage: "display")
                }
                Divider()
                if model.phase == .error {
                    Button {
                        model.restart()
                    } label: {
                        Label("重新启动麦克风服务", systemImage: "restart")
                    }
                }
                Button {
                    speakerController.restartApp()
                } label: {
                    Label("重启 App（授权后）", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    speakerController.shutdown()
                    model.quit()
                } label: {
                    Label("退出 Mac 音频枢纽", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }
}

private struct HubModeSwitcher: View {
    @Binding var mode: HubMode
    let micLive: Bool
    @ObservedObject var speakerModel: SpeakerModel

    var body: some View {
        HStack(spacing: 2) {
            tab(.mic, active: micLive)
            tab(.karaoke, active: micLive)
            tab(.speaker, active: speakerModel.isCapturing || speakerModel.devices.contains(where: \.isActive))
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.20)))
        .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func tab(_ item: HubMode, active: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { mode = item }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                if active {
                    Circle()
                        .fill(Color.airMint)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(mode == item ? .white : .white.opacity(0.48))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(mode == item ? Color.white.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MicStatusPill: View {
    @EnvironmentObject private var model: AppModel

    private var color: Color {
        switch model.phase {
        case .live: return Color.airMint
        case .pageOpen: return Color(red: 0.55, green: 0.72, blue: 1.0)
        case .waiting: return Color.airWarning
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.45)
        case .starting: return Color.airMuted
        }
    }

    var body: some View {
        StatusCapsule(text: model.statusTitle, color: color)
    }
}

private struct KaraokeStatusPill: View {
    @EnvironmentObject private var model: AppModel

    private var color: Color {
        model.isLive ? Color.airMint : Color.airWarning
    }

    private var text: String {
        if model.isLive {
            return "K歌人声 · \(model.latencyMilliseconds) ms"
        }
        return "K歌模式 · 等麦克风"
    }

    var body: some View {
        StatusCapsule(text: text, color: color)
    }
}

private struct SpeakerStatusPill: View {
    @ObservedObject var model: SpeakerModel

    private var color: Color {
        if !model.serverRunning { return Color(red: 1.0, green: 0.42, blue: 0.45) }
        if model.hasScreenPermission == false { return Color.airWarning }
        if model.isCapturing { return Color.airMint }
        if model.devices.contains(where: \.isActive) { return Color.airMint }
        return Color.airWarning
    }

    private var text: String {
        if !model.serverRunning { return "音箱服务未运行" }
        if model.hasScreenPermission == false { return "音箱待授权" }
        if model.isCapturing { return "正在推送系统音频" }
        let active = model.devices.filter { $0.isActive }.count
        if active > 0 { return "\(active) 台设备收听中" }
        if !model.devices.isEmpty { return "\(model.devices.count) 台设备已连接" }
        return "音箱服务运行中"
    }

    var body: some View {
        StatusCapsule(text: text, color: color)
    }
}

private struct StatusCapsule: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color.opacity(0.95))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.20), lineWidth: 1))
    }
}

// MARK: - QR panel

private struct QRPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "qrcode")
                    .font(.system(size: 10, weight: .bold))
                Text("扫码连接 · 无需安装")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
            }
            .foregroundStyle(Color.airMint)
            .padding(.bottom, 8)

            Text("手机就是麦克风")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("同一 Wi-Fi 下，可同时连接最多 8 台手机")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.airMuted)
                .padding(.top, 4)
                .padding(.bottom, 14)

            QRCodeCard()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 13)

            URLRow()
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 9) {
                InstructionRow(number: 1, text: "让手机和 Mac 连接同一个 Wi-Fi")
                InstructionRow(number: 2, text: "用相机或浏览器扫码，多台手机可重复扫描")
                InstructionRow(number: 3, text: "首次打开选择「显示详细信息 → 继续访问」")
                InstructionRow(number: 4, text: "在手机上点「开始传音」并允许麦克风")
            }

            Spacer(minLength: 10)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.airWarning)
                    .padding(.top, 1)
                Text("首次看到证书提示是正常的，请选择继续访问。若 macOS 询问本地网络权限，请点「允许」。声音不会离开局域网。")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.airWarning.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.airWarning.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.airWarning.opacity(0.12), lineWidth: 1)
            )
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PanelBackground())
    }
}

private struct QRCodeCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 12)

            if let image = model.qrImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(10)
                    .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black.opacity(0.55))
                    Text("正在生成二维码…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.black.opacity(0.5))
                }
            }

            QRCornerBrackets()
                .padding(7)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 232)
    }
}

private struct QRCornerBrackets: View {
    var body: some View {
        GeometryReader { geo in
            let length: CGFloat = 17
            let width: CGFloat = 2
            let color = Color.airMint.opacity(0.72)
            Path { path in
                path.move(to: CGPoint(x: 0, y: length))
                path.addLine(to: .zero)
                path.addLine(to: CGPoint(x: length, y: 0))

                path.move(to: CGPoint(x: geo.size.width - length, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: length))

                path.move(to: CGPoint(x: geo.size.width, y: geo.size.height - length))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.addLine(to: CGPoint(x: geo.size.width - length, y: geo.size.height))

                path.move(to: CGPoint(x: length, y: geo.size.height))
                path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                path.addLine(to: CGPoint(x: 0, y: geo.size.height - length))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct URLRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.airMint.opacity(0.8))
            Text(model.serverURL?.absoluteString ?? "正在准备地址…")
                .font(.system(size: 11.2, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                model.copyURL()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                    Text(model.copied ? "已复制" : "复制")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(model.copied ? Color.airMint : .white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.airMint)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.airMint.opacity(0.11)))
                .overlay(Circle().stroke(Color.airMint.opacity(0.18), lineWidth: 0.8))
            Text(text)
                .font(.system(size: 11.2, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Status panel

private struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("实时监听")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.airMint)
                    Text(model.isLive ? "声音已同步到 Mac" : "连接状态")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                if model.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(Color.airMint).frame(width: 5, height: 5)
                        Text("LIVE")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .tracking(1.2)
                    }
                    .foregroundStyle(Color.airMint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.airMint.opacity(0.10)))
                    .overlay(Capsule().stroke(Color.airMint.opacity(0.18), lineWidth: 1))
                }
            }

            PulseOrb(live: model.isLive, level: model.level)
                .frame(height: 126)
                .padding(.top, 2)

            Text(model.statusTitle)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 2)

            Text(model.statusDetail)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(model.phase == .error ? Color(red: 1.0, green: 0.55, blue: 0.56) : Color.airMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 350)
                .padding(.top, 3)
                .padding(.bottom, 12)

            HStack(spacing: 10) {
                MetricTile(
                    title: "端到端延迟",
                    value: model.isLive && model.latencyMilliseconds > 0 ? "\(model.latencyMilliseconds) ms" : "—",
                    detail: model.outputLatencyMilliseconds > 0 ? "含系统输出 \(model.outputLatencyMilliseconds)ms" : "声音到手时间",
                    icon: "bolt.fill",
                    accent: Color.airMint
                )
                MetricTile(
                    title: "抖动缓冲",
                    value: model.isLive ? "\(model.queueMilliseconds) ms" : "—",
                    detail: model.underruns > 0 ? "卡顿 \(model.underruns) 次" : "自适应稳定",
                    icon: "waveform.path",
                    accent: Color.airIndigo
                )
            }
            .padding(.bottom, 9)

            HStack(spacing: 10) {
                MetricTile(
                    title: "音质",
                    value: model.qualityLabel,
                    detail: "未压缩 PCM",
                    icon: "hifispeaker.fill",
                    accent: Color.airWarning
                )
                MetricTile(
                    title: "实时码率",
                    value: model.isLive && model.kbps > 0 ? "\(model.kbps) kbps" : "—",
                    detail: model.phoneCount > 0 ? "\(model.phoneCount) 路合计" : "本机输入",
                    icon: "antenna.radiowaves.left.and.right",
                    accent: Color.airTeal
                )
            }
            .padding(.bottom, 13)

            LevelMeter(level: model.level, live: model.isLive)
                .padding(.bottom, 11)

            VolumeRow()
                .padding(.bottom, 10)

            OutputSpeakerRow()
                .padding(.bottom, 11)

            HStack(spacing: 9) {
                Button {
                    model.testTone()
                } label: {
                    Label("测试当前输出", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    model.openSoundSettings()
                } label: {
                    Label("声音设置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.bottom, 12)

            if model.phase == .error {
                Button {
                    model.restart()
                } label: {
                    Label("重新启动服务", systemImage: "restart")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 10)
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelBackground())
    }
}

private struct PulseOrb: View {
    let live: Bool
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if live {
                    ForEach(0..<3, id: \.self) { index in
                        let progress = ((time * 0.52) + Double(index) / 3.0)
                            .truncatingRemainder(dividingBy: 1.0)
                        Circle()
                            .stroke(Color.airMint.opacity((1.0 - progress) * 0.22), lineWidth: 1.1)
                            .frame(width: 102 + progress * 54, height: 102 + progress * 54)
                    }
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                live ? Color.airMint.opacity(0.30) : Color.airIndigo.opacity(0.20),
                                live ? Color.airTeal.opacity(0.10) : Color.airIndigo.opacity(0.06),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 64
                        )
                    )
                    .frame(width: 132, height: 132)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: live
                                ? [Color.airMint.opacity(0.24), Color.airTeal.opacity(0.13)]
                                : [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)
                    .overlay(
                        Circle().stroke(
                            live ? Color.airMint.opacity(0.34) : Color.white.opacity(0.10),
                            lineWidth: 1
                        )
                    )
                    .shadow(color: live ? Color.airMint.opacity(0.20) : .clear, radius: 20)

                Image(systemName: live ? "waveform" : "mic.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(live ? Color.airMint : .white.opacity(0.68))
                    .symbolEffect(.variableColor.iterative, isActive: live)

                if live {
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<7, id: \.self) { index in
                            let wave = 0.55 + 0.45 * sin(time * 5.2 + Double(index) * 1.3)
                            let energy = max(0.10, min(1.0, CGFloat(level) * 2.8))
                            Capsule()
                                .fill(Color.airMint.opacity(0.68))
                                .frame(width: 3, height: 4 + 17 * energy * CGFloat(wave))
                        }
                    }
                    .offset(y: 54)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(0.09))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.airMuted)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }
}

private struct OutputSpeakerRow: View {
    @EnvironmentObject private var model: AppModel

    private var subtitle: String {
        if !model.isUsingSystemDefaultOutput {
            return "系统默认：\(model.systemDefaultOutputName)"
        }
        if let device = model.selectedOutputDevice {
            if device.isBluetooth { return "蓝牙输出 · 延迟较高" }
            if device.isBuiltIn { return "内置扬声器 · 最低延迟" }
        }
        return "当前系统默认输出"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.airMint.opacity(0.10))
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.airMint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("输出音箱")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.airMuted)
                    if !model.isUsingSystemDefaultOutput {
                        Text("非系统默认")
                            .font(.system(size: 7.8, weight: .bold))
                            .foregroundStyle(Color.airWarning.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.airWarning.opacity(0.10)))
                    }
                }
                Text(model.outputDeviceName)
                    .font(.system(size: 11.2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(model.outputDeviceIsBluetooth ? Color.airWarning.opacity(0.75) : .white.opacity(0.30))
            }

            Spacer(minLength: 4)

            Button {
                model.testTone()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.airMint.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .help("在当前选择的输出音箱上播放测试音")

            Menu {
                Button {
                    model.useSystemDefaultOutput()
                } label: {
                    Label("使用系统默认（\(model.systemDefaultOutputName)）", systemImage: "arrow.uturn.backward")
                }
                Divider()
                ForEach(model.outputDevices) { device in
                    Button {
                        model.selectOutputDevice(device)
                    } label: {
                        HStack {
                            Text(device.name)
                            if device.id == model.selectedOutputDeviceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("切换")
                        .font(.system(size: 9.5, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.032))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }
}

private struct LevelMeter: View {
    let level: Float
    let live: Bool

    private var normalized: CGFloat {
        guard live else { return 0.02 }
        return max(0.02, min(1.0, CGFloat(level) * 2.2))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("输入电平")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.airMuted)
                Spacer()
                Text(live ? "\(Int(min(100, max(0, level * 220))))%" : "待机")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.46))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.055))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.airMint, Color.airTeal, Color.airWarning],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, geo.size.width * normalized))
                        .shadow(color: Color.airMint.opacity(live ? 0.28 : 0), radius: 5)
                }
            }
            .frame(height: 5)
        }
        .animation(.easeOut(duration: 0.09), value: normalized)
    }
}

private struct VolumeRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.airMint.opacity(0.9))
                .frame(width: 16)
            Text("播放音量")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.airMuted)
                .frame(width: 54, alignment: .leading)
            Slider(value: $model.volume, in: 0...1)
                .tint(Color.airMint)
            Text("\(Int(model.volume * 100))%")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct SourceStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("输入源")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.airMint)
                Text("\(model.phoneCount) 路手机 · 最多 8 路")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                if model.isLive {
                    Text(model.sessionTimeLabel)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.airMint.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.airMint.opacity(0.07)))
                }
                if model.localMicEnabled || model.systemMicEnabled {
                    Label("请戴耳机，避免啸叫", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.airWarning.opacity(0.9))
                } else {
                    Text("本机 / iPhone 麦克风未开启")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.26))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    LocalMicChip()
                    if !model.systemInputDevices.isEmpty {
                        SystemMicChip()
                    }
                    if model.phoneSources.isEmpty {
                        WaitingForPhoneChip()
                    } else {
                        ForEach(model.phoneSources) { source in
                            PhoneSourceChip(source: source)
                        }
                    }
                    if model.systemInputDevices.isEmpty {
                        Button {
                            AudioDevices.openSoundInputSettings()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "iphone")
                                Text("添加 iPhone 麦克风")
                            }
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 11)
                            .frame(height: 49)
                            .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.035)))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.06), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("打开系统设置 → 声音 → 输入，选择附近的 iPhone（连续互通相机）")
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PanelBackground())
    }
}

private struct LocalMicChip: View {
    @EnvironmentObject private var model: AppModel

    private var level: CGFloat {
        CGFloat(model.localSource?.level ?? 0)
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.localMicEnabled ? Color.airMint.opacity(0.13) : Color.white.opacity(0.05))
                Image(systemName: model.localMicEnabled ? "mic.fill" : "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.localMicEnabled ? Color.airMint : Color.airMuted)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("本机麦克风")
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(model.localMicBusy ? "正在请求权限…" : (model.localMicEnabled ? "直接扩音中" : "点击开启扩音"))
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(model.localMicEnabled ? Color.airMint.opacity(0.8) : .white.opacity(0.32))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if model.localMicBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Toggle("", isOn: Binding(
                    get: { model.localMicEnabled },
                    set: { model.setLocalMic($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.airMint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 198, height: 49)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(model.localMicEnabled ? Color.airMint.opacity(0.055) : Color.white.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(model.localMicEnabled ? Color.airMint.opacity(0.22) : Color.white.opacity(0.05), lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) {
            if model.localMicEnabled {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.airMint.opacity(0.7))
                        .frame(width: max(3, geo.size.width * min(1, level * 2.2)), height: 2)
                        .offset(x: 10, y: 47)
                }
                .frame(height: 2)
            }
        }
    }
}

private struct SystemMicChip: View {
    @EnvironmentObject private var model: AppModel

    private var level: CGFloat {
        CGFloat(model.systemSource?.level ?? 0)
    }

    private var deviceName: String {
        model.selectedSystemInput?.shortName ?? "iPhone 麦克风"
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.systemMicEnabled ? Color.airMint.opacity(0.13) : Color.white.opacity(0.05))
                Image(systemName: model.systemMicEnabled ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.systemMicEnabled ? Color.airMint : Color.airMuted)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName)
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Text(model.systemMicBusy ? "正在连接…" : (model.systemMicEnabled ? "Apple 连续互通 · 低延迟" : "系统原生 iPhone 麦克风"))
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(model.systemMicEnabled ? Color.airMint.opacity(0.8) : .white.opacity(0.32))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if model.systemMicBusy {
                ProgressView().controlSize(.mini)
            } else {
                if model.systemInputDevices.count > 1 {
                    Menu {
                        ForEach(model.systemInputDevices) { device in
                            Button(device.shortName) {
                                model.selectSystemInput(device)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 15)
                }
                Toggle("", isOn: Binding(
                    get: { model.systemMicEnabled },
                    set: { model.setSystemMic($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.airMint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 230, height: 49)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(model.systemMicEnabled ? Color.airMint.opacity(0.055) : Color.white.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(model.systemMicEnabled ? Color.airMint.opacity(0.22) : Color.white.opacity(0.05), lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) {
            if model.systemMicEnabled {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.airMint.opacity(0.7))
                        .frame(width: max(3, geo.size.width * min(1, level * 2.2)), height: 2)
                        .offset(x: 10, y: 47)
                }
                .frame(height: 2)
            }
        }
    }
}

private struct PhoneSourceChip: View {
    @EnvironmentObject private var model: AppModel
    let source: MicSourceUI

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                Image(systemName: source.isMuted ? "speaker.slash.fill" : "iphone.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(source.isMuted ? Color.airWarning.opacity(0.75) : Color.airMint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Text("第 \(source.channel) 路 · \(String(format: "%.1f", source.sampleRate / 1000)) kHz")
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                model.toggleMute(source)
            } label: {
                Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(source.isMuted ? Color.airWarning.opacity(0.85) : .white.opacity(0.45))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(source.isMuted ? "取消静音" : "静音这一路")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 198, height: 49)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.airMint.opacity(source.isMuted ? 0.15 : 0.55))
                    .frame(width: max(3, geo.size.width * min(1, CGFloat(source.level) * 2.2)), height: 2)
                    .offset(x: 10, y: 47)
            }
            .frame(height: 2)
        }
    }
}

private struct WaitingForPhoneChip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "qrcode")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.airMuted.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .pageOpen ? "手机页面已连接" : "等待手机扫码")
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(model.phase == .pageOpen ? "等待手机端点击开麦" : "可同时接入多台手机")
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 198, height: 49)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.018))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.white.opacity(0.08))
        )
    }
}

// MARK: - Footer and shared chrome

private struct FooterView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var speakerModel: SpeakerModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8.5, weight: .semibold))
            Text("局域网直连 · 双服务独立运行")
                .font(.system(size: 9.8, weight: .medium))
            Circle().fill(Color.white.opacity(0.18)).frame(width: 2.5, height: 2.5)
            Text("Hub 2.0")
                .font(.system(size: 9.8, weight: .medium))

            Spacer(minLength: 10)

            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.serverReady ? Color.airMint.opacity(0.8) : Color.airWarning.opacity(0.7))
                        .frame(width: 4, height: 4)
                    Text("麦克风 :\(String(model.port))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(speakerModel.serverRunning ? Color.airMint.opacity(0.8) : Color(red: 1, green: 0.42, blue: 0.45).opacity(0.8))
                        .frame(width: 4, height: 4)
                    Text("音箱 :\(String(speakerModel.port))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
            }

            if model.serverReady {
                HStack(spacing: 7) {
                    if model.outputDevices.isEmpty {
                        Text("输出：\(model.outputDeviceName)")
                            .font(.system(size: 9.2, weight: .medium))
                    } else {
                        Menu {
                            ForEach(model.outputDevices) { device in
                                Button {
                                    model.selectOutputDevice(device)
                                } label: {
                                    HStack {
                                        Text(device.name)
                                        if device.id == model.selectedOutputDeviceID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "hifispeaker.fill")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text("输出：\(model.outputDeviceName)")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if model.outputDeviceIsBluetooth {
                                    Text("蓝牙")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Color.airWarning.opacity(0.9))
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("选择麦克风播放输出设备；内置扬声器或有线输出延迟最低")
                    }
                }
            } else {
                Text("麦克风服务启动中…")
                    .font(.system(size: 9.2, weight: .medium))
            }
        }
        .foregroundStyle(.white.opacity(0.30))
        .padding(.horizontal, 5)
    }
}

private struct PanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.062), Color.white.opacity(0.032)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.30), radius: 24, x: 0, y: 14)
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.airMint)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color(red: 0.07, green: 0.10, blue: 0.16).opacity(0.96))
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.8, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.04 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.airInk)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.airMint.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}
