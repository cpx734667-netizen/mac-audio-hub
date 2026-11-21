# 与 macOS 版的差异

| 能力 | macOS 参考实现 | Windows 版 | 说明 |
|---|---|---|---|
| 系统声音捕获 | ScreenCaptureKit，`excludesCurrentProcessAudio` | WASAPI **进程回环**（ActivateAudioInterfaceAsync，排除本进程树）；失败降级为默认输出设备 loopback | 不依赖屏幕录制权限，也不需要虚拟声卡 |
| 系统声音权限 | 屏幕录制权限 | 无额外权限；loopback 不需要屏幕录制 | 首次监听端口仍需防火墙放行 |
| 手机麦克风服务 | Network.framework + TLS（SecIdentity） | Kestrel HTTPS/WSS（8765），`X509Certificate2` 自签名证书 | 证书 SAN 覆盖当前所有 LAN IPv4 + localhost |
| 证书存储 | Keychain | `%LOCALAPPDATA%\AirMicHub\cert.pfx`，PFX 用 **DPAPI（当前用户）** 加密 | IP 变化自动重建；不写入系统信任库 |
| 本机麦克风 | AVAudioEngine / CoreAudio | NAudio `WasapiCapture` + 自研重采样 | 支持 Float32 / PCM16 / 24 / 32 |
| 多路混音 | AVAudioPlayerNode 调度 | 拉模型 `MixEngine`：WASAPI 输出线程按 5 ms 拉取 | 每路 10 ms 预缓冲、30 ms 上限、超限丢最旧 |
| 输出设备切换 | CoreAudio 默认设备 / AVAudioEngine | NAudio `WasapiOut` 指定 MMDevice；失败/拔出回退默认设备并提示 | 一个输出管线，避免多个 WasapiOut 抢设备 |
| 默认输出切换 | CoreAudio 属性 | 未公开的 `IPolicyConfig` COM + 回读校验 | Windows 无稳定公开 API；失败时提示手动切换，不谎报成功 |
| iPhone 连续互通麦克风 | 支持（Continuity） | **不支持**，只支持普通 Windows 输入设备和浏览器手机麦克风 | 这是 macOS 独占能力，不伪造 |
| Now Playing | MediaRemote（含私有框架） | Windows GSMTC（`Windows.Media.Control`） | 平台不暴露会话时显示「等待音乐平台播放」 |
| 歌词 | LRCLIB + `.lrc` | 相同 | 增加了手动歌词时钟与 ±0.5 s 偏移 |
| 8787 手机播放器 | 300 ms 目标缓冲，Float32/Int16 | 相同，复用同一套 JS 缓冲逻辑 | 仅改文案；增加应用层 `ping→pong` 心跳 |
| 服务端进程模型 | 两个 NWListener（8765/8787） | 一个 Kestrel Host，两个 Listener，按 `LocalPort` 分发 | 两个服务同一进程、独立音频管线、可同时运行 |
| 原唱/伴奏切换 | 只能平台内切换 | 相同，并在 UI/README 明确说明 | 第三方平台无公开接口 |
| 打包 | `.app` bundle / DMG | self-contained 单文件 `AirMicHub.exe` + zip | 目标机无需安装 .NET |
| 更新/权限 | 屏幕录制授权流程 | 无屏幕录制授权；麦克风权限走 Windows 隐私设置 | 首次使用建议打开 `ms-settings:privacy-microphone` |

## 行为保持

- 8765 协议（hello/ready/stats/ping/pong/bye、8 路上限、二进制 Int16LE 5 ms 帧）与
  `Resources/phone.html`、`pcm-worklet.js` 完全兼容，页面只改了 “Mac”→“电脑” 的文案。
- 8787 协议（device/start/stop/ready/state/error、Float32LE/Int16LE、设备 ID 去重、
  300 ms 缓冲）与 `WebAssets.swift` 的播放器逻辑一致。
- UI 信息架构保持三页（麦克风 / K 歌 / 音箱）与深色卡片风格，但按 Windows 尺寸重写。
