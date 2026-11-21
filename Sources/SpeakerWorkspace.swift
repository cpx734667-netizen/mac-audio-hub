import SwiftUI
import AppKit

struct SpeakerWorkspace: View {
    @ObservedObject var model: SpeakerModel
    let controller: AppController
    let micLive: Bool
    let width: CGFloat

    private var wide: Bool { width >= 980 }

    var body: some View {
        VStack(spacing: 16) {
            if model.hasScreenPermission == false {
                permissionBanner
            }

            if wide {
                HStack(alignment: .top, spacing: 16) {
                    SpeakerConnectionCard(model: model)
                        .frame(width: 410)
                        .frame(height: 370)
                    SpeakerControlCard(model: model, controller: controller)
                        .frame(maxWidth: .infinity)
                        .frame(height: 370)
                }
            } else {
                VStack(spacing: 16) {
                    SpeakerConnectionCard(model: model)
                        .frame(height: 370)
                    SpeakerControlCard(model: model, controller: controller)
                        .frame(height: 370)
                }
            }

            if micLive && model.isCapturing {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.airMint)
                    Text("双功能隔离已启用：系统音频捕获会排除本 App 自身的麦克风播放输出，不会把手机声音再次广播。其他 App 的声音仍会正常捕获。")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.airMint.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.airMint.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.airMint.opacity(0.14), lineWidth: 1))
            }

            SpeakerDevicesCard(model: model, controller: controller)

            if let error = model.captureError, !error.isEmpty {
                errorCard(error)
            }
        }
        .onAppear {
            if model.hasScreenPermission != true {
                controller.requestScreenRecordingPermission()
            } else {
                controller.checkScreenPermission()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.hasScreenPermission != true {
                controller.checkScreenPermission()
            }
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.airWarning)
                Text("需要「屏幕录制」权限才能捕获系统音频")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
            }
            Text("macOS 把系统音频捕获归在「屏幕录制」权限里；本 App 只取声音，不录屏幕。屏幕录制不会弹授权框，需要在设置列表里手动勾选；如果列表里没有本 App，点设置窗口左下角的 +，选择桌面的「Mac 音频枢纽.app」。勾选后必须重启 App。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.airMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("请求权限") { controller.requestScreenRecordingPermission() }
                    .buttonStyle(HubPrimaryButtonStyle())
                Button("打开系统设置") { controller.openScreenRecordingSettings() }
                    .buttonStyle(HubSecondaryButtonStyle())
                Button("重新检测") { controller.checkScreenPermission() }
                    .buttonStyle(HubSecondaryButtonStyle())
                Button("重启 App") { controller.restartApp() }
                    .buttonStyle(HubSecondaryButtonStyle())
                Button("重置旧授权") { controller.resetScreenRecordingPermission() }
                    .buttonStyle(HubSecondaryButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.airWarning.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.airWarning.opacity(0.18), lineWidth: 1))
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("系统音频捕获失败", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.52))
            Text(error)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("屏幕录制设置") { controller.openScreenRecordingSettings() }
                    .buttonStyle(HubSecondaryButtonStyle())
                Button("重启 App") { controller.restartApp() }
                    .buttonStyle(HubSecondaryButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.16), lineWidth: 1))
    }
}

// MARK: - Connection

private struct SpeakerConnectionCard: View {
    @ObservedObject var model: SpeakerModel

    private var urlString: String {
        guard let ip = model.ipAddresses.first else { return "http://127.0.0.1:\(model.port)/" }
        return "http://\(ip):\(model.port)/"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                Text("收听端 · 无需安装")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
            }
            .foregroundStyle(Color.airIndigo)

            Text("手机就是 Mac 的音箱")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 8)

            Text("把 Mac 正在播放的声音，实时广播到同一 Wi-Fi 下的手机")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.airMuted)
                .padding(.top, 4)
                .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(.white)
                    if let image = QRCodeGenerator.makeImage(for: urlString, pixelSize: 9) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(9)
                    }
                }
                .frame(width: 164, height: 164)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 9) {
                    Text("扫码播放")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                    Text("手机 / 平板浏览器打开后点「开始播放」")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(urlString)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.airIndigo.opacity(0.9))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(urlString, forType: .string)
                    } label: {
                        Label("复制播放地址", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(HubSecondaryButtonStyle())

                    HStack(spacing: 5) {
                        Circle().fill(model.serverRunning ? Color.airMint : Color.red).frame(width: 5, height: 5)
                        Text(model.serverRunning ? "端口 \(String(model.port)) 运行中" : "服务未运行")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
            }

            Spacer(minLength: 0)

            Text("同一设备重复打开会只保留最新页面，避免双声。")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
                .padding(.top, 12)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SpeakerCardBackground())
    }
}

// MARK: - Capture controls

private struct SpeakerControlCard: View {
    @ObservedObject var model: SpeakerModel
    let controller: AppController

    private var activeCount: Int { model.devices.filter { $0.isActive }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 10, weight: .bold))
                Text("推流控制")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
            }
            .foregroundStyle(Color.airMint)

            Text("Mac 系统音频广播")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 8)

            Text("捕获播放器、浏览器、会议和其他 App 的声音")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.airMuted)
                .padding(.top, 4)
                .padding(.bottom, 16)

            Toggle(isOn: Binding(
                get: { model.captureEnabled },
                set: { controller.setCaptureEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("系统音频推流")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(model.isCapturing ? "正在捕获并广播系统声音" : "开启后，有设备播放时才捕获")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(model.isCapturing ? Color.airMint.opacity(0.8) : .white.opacity(0.35))
                }
            }
            .toggleStyle(.switch)
            .tint(Color.airMint)

            Divider()
                .overlay(Color.white.opacity(0.07))
                .padding(.vertical, 13)

            Toggle(isOn: Binding(
                get: { model.efficientMode },
                set: { controller.setEfficientMode($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("高效传输")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("Int16 · 带宽减半，适合多设备")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .toggleStyle(.switch)
            .tint(Color.airIndigo)

            HStack(spacing: 8) {
                statusTile(
                    icon: "speaker.wave.2.fill",
                    title: "收听设备",
                    value: "\(activeCount) / \(model.devices.count)",
                    color: Color.airIndigo
                )
                statusTile(
                    icon: "dot.radiowaves.left.and.right",
                    title: "系统捕获",
                    value: model.isCapturing ? "运行中" : "待机",
                    color: model.isCapturing ? Color.airMint : Color.airWarning
                )
            }
            .padding(.top, 14)

            if model.hasScreenPermission == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("需要屏幕录制权限，见上方提示")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(Color.airWarning.opacity(0.8))
                .padding(.top, 12)
            } else if model.hasScreenPermission == nil {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text("正在检测屏幕录制权限；若未弹出系统授权框，请点「屏幕录制设置」")
                        .font(.system(size: 9.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white.opacity(0.36))
                .padding(.top, 12)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    controller.checkScreenPermission()
                } label: {
                    Label("检测权限", systemImage: "checkmark.shield")
                }
                .buttonStyle(HubSecondaryButtonStyle())

                Button {
                    controller.openScreenRecordingSettings()
                } label: {
                    Label("屏幕录制设置", systemImage: "display")
                }
                .buttonStyle(HubSecondaryButtonStyle())
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SpeakerCardBackground())
    }

    private func statusTile(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.34))
                Text(value)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.032)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
}

// MARK: - Devices

private struct SpeakerDevicesCard: View {
    @ObservedObject var model: SpeakerModel
    let controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("收听设备")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.airIndigo)
                Text("\(model.devices.count) 台")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                Spacer()
                Text("每台可独立开关推流")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.26))
            }

            if model.devices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.16))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("暂无收听设备")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("让手机扫描上面的播放二维码，打开页面即可出现在这里")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.022)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.white.opacity(0.07)))
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.devices) { device in
                            deviceRow(device)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
        .padding(16)
        .background(SpeakerCardBackground())
    }

    private func deviceRow(_ device: SpeakerDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.isActive ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(device.isActive ? Color.airMint : Color.airMuted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.045)))

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                HStack(spacing: 6) {
                    Text(device.ip)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                    Circle().fill(.white.opacity(0.16)).frame(width: 2, height: 2)
                    Text(Self.timeFormatter.string(from: device.connectedAt))
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            Toggle(isOn: Binding(
                get: { device.isActive },
                set: { controller.toggleDevice(device.id, active: $0) }
            )) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(Color.airMint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.028)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.045), lineWidth: 1))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - Shared chrome

private struct SpeakerCardBackground: View {
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

private struct HubSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.74))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.04 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct HubPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Color.airInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.airMint.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}
