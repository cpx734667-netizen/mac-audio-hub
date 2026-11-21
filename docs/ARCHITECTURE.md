# 架构说明

## 两条独立链路

### 手机麦克风 :8765

```
手机浏览器
  AudioWorklet 5ms 帧
  Int16 PCM over WSS
        │
        ▼
HTTPS/WSS Server (Network.framework)
  ├─ 自签名 TLS
  ├─ 最多 8 路手机
  └─ 每路自适应队列
        │
        ▼
AudioMixer (AVAudioEngine)
  ├─ 48 kHz 重采样
  ├─ 多路混音
  ├─ 本机麦克风
  └─ iPhone 连续互通麦克风
        │
        ▼
输出音箱 (CoreAudio)
```

### Mac 音箱 :8787

```
Mac 系统音频（其他 App）
        │
        ▼
ScreenCaptureKit（排除本 App 自身输出）
        │
        ▼
HTTP / WebSocket Server :8787
        │
        ▼
手机浏览器播放器（约 300ms 同步缓冲）
```

两个服务使用不同端口、不同引擎，可同时运行。

## 音频参数

- 手机端：48 kHz，单声道，Int16，5 ms 帧；
- 混音：48 kHz，Float32，5 ms 块；
- 输出：目标 15 ms 水位，启动 10 ms；
- Mac 音箱：多设备同步目标约 300 ms。

## iPhone Continuity

- 使用 AVFoundation `AVCaptureDevice` 发现连续互通麦克风；
- `AVCaptureAudioDataOutput` 采集原生 PCM；
- 在启动采集前先注册混音源，避免启动阻塞期间丢帧；
- 支持 Float32 / Int16 / Int32 和交错/非交错格式。

## Now Playing

- 通过 macOS 私有 `MediaRemote.framework` 读取系统当前播放信息；
- 仅用于 K 歌歌词匹配和播放控制；
- 私有接口可能随系统更新失效，不影响手机麦克风/Mac 音箱主功能。

## 权限与签名

- 本地网络：NWListener / Bonjour；
- 麦克风：手机浏览器、本机麦克风、iPhone 原生；
- 屏幕录制：ScreenCaptureKit 系统音频；
- 构建为 ad-hoc 签名，TCC 记录可能随构建变化。
