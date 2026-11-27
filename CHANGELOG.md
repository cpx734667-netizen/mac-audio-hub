# Changelog

## Unreleased — macOS audio stability

- Fix intermittent clicks/gaps when a 5 ms phone frame arrives partially (partial source chunks are now held/filled instead of skipped).
- Raise phone jitter buffer from 10/30 ms to 20/60 ms; output target from 15 ms to 20 ms.
- Add soft-knee limiter and DC blocker to prevent multi-source clipping/thumps.
- Add `droppedSourceFrames` diagnostics remains available.

## Windows 1.0.0 — 2026-11

首个 Windows 原生版（.NET 8 / WPF / Kestrel / NAudio）。

- 手机麦克风 8765 HTTPS/WSS，最多 8 路；
- Windows 系统声音 8787，WASAPI loopback / 进程回环；
- K 歌页、GSMTC Now Playing、LRCLIB/LRC、统一输出；
- self-contained win-x64 单文件发布；
- 34 个自动化测试通过，具体见 `windows/TEST_REPORT.md`。

## 2.0.0 — 2026-11

首个公开版本。

### 新增

- 三 Tab 界面：手机麦克风 / K 歌 / Mac 音箱
- 手机浏览器麦克风，最多 8 路混音
- Mac 本机麦克风扩音
- Mac 系统音频 → 手机（ScreenCaptureKit）
- K 歌模式：平台伴奏、LRCLIB 歌词、手动搜歌词、LRC、歌词时钟、输出统一
- iPhone 连续互通麦克风（AVFoundation，实验性）
- 输出音箱选择、测试音、系统输出统一
- 可调整窗口大小，适配窄窗口

### 修复 / 优化

- 5 ms 音频帧与自适应缓冲，手机麦克风链路约 30–50 ms
- 高精度音频重采样
- Mac 系统音频排除本 App 自身输出
- 屏幕录制权限重置与引导
- iPhone 原生麦克风采集不再阻塞主线程，先注册混音源再启动采集
