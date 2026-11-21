import SwiftUI
import AppKit

@main
struct AirMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1160, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("复制连接地址") { model.copyURL() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let sizeString = ProcessInfo.processInfo.environment["AIRMIC_WINDOW_SIZE"] {
            let parts = sizeString.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = NSApp.windows.first {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            }
        }
        if let path = ProcessInfo.processInfo.environment["AIRMIC_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if let view = NSApp.windows.first?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
