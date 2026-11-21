import Foundation
import SwiftUI

/// 一台已连接的设备（浏览器端）
struct SpeakerDevice: Identifiable {
    let id: UUID
    var name: String
    var ip: String
    var connectedAt: Date
    var isActive: Bool   // 是否向该设备推流
}

/// 全局状态模型，供 SwiftUI 与服务器共享
final class SpeakerModel: ObservableObject {
    @Published var serverRunning = false
    @Published var serverError: String?
    @Published var port: UInt16 = 8787
    @Published var ipAddresses: [String] = []
    @Published var devices: [SpeakerDevice] = []
    @Published var isCapturing = false
    @Published var captureError: String?
    @Published var captureEnabled = true
    /// nil=尚未检测；true=已获得屏幕录制权限；false=未授权
    @Published var hasScreenPermission: Bool?
    /// 高效传输模式（16bit，带宽减半）
    @Published var efficientMode = false
}
