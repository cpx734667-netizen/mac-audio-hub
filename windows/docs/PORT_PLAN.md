# AirMic Hub — Windows 移植计划

版本：1.0 · 日期：2026-11-21 · 目标：Windows 10 2004+ / Windows 11，x64

## 1. 技术栈

| 层 | 选择 | 理由 |
|---|---|---|
| UI | WPF (.NET 8, `net8.0-windows10.0.19041.0`) | 深色自定义 UI 成熟，打包简单；WinUI 3 的 MSIX/证书链路对家庭用户过重 |
| 服务端 | ASP.NET Core Kestrel 单进程双监听：`8765` HTTPS/WSS + `8787` HTTP/WS | 一个 Host 两个 Listener，天然同时运行；证书/跨网卡绑定比 HttpListener 稳定 |
| 音频 | NAudio 2.2.1（WASAPI） | WASAPI capture / loopback / WasapiOut 直接可用，设备枚举稳定 |
| 系统音频捕获 | process loopback（ActivateAudioInterfaceAsync + 排除本进程树），失败降级为默认输出设备 loopback | 避免 8787 把 App 自己的人声监听回授给手机 |
| Now Playing | Windows GSMTC (`Windows.Media.Control`) | 读取平台歌曲/播放控制，不可用时如实显示“未检测到” |
| 歌词 | LRCLIB + 本地 `.lrc` | 与 macOS 版同源 |
| 二维码 | QRCoder（PngByteQRCode） | 无 GDI+ 依赖，裁剪安全 |
| 证书 | `CertificateRequest` 自签名 + SAN(LAN IP/localhost) + PFX 用 DPAPI(CurrentUser) 加密落盘 | 手机浏览器只接受 SAN 覆盖的地址 |

## 2. 模块拆分（与任务书 §15 对齐）

```
windows-app/
  AirMicHub.sln
  src/
    AirMicHub.Core/       协议模型、PCM 转换/重采样、每路队列+混音核心、
                          LRC 解析、设置、网卡枚举、证书、共享状态 HubState
    AirMicHub.Audio/      NAudio 设备枚举、本机麦克风采集、监听输出、
                          系统 loopback / process loopback 捕获
    AirMicHub.Server/     Kestrel 宿主、8765 手机麦克风 Hub、8787 音箱 Hub、
                          内嵌 web 资源（phone.html / pcm-worklet.js / speaker.html）
    AirMicHub.Lyrics/     LRCLIB 客户端、歌词时钟
    AirMicHub.Platform/   GSMTC、平台启动、Windows 默认输出切换（IPolicyConfig）
    AirMicHub.App/        WPF 三 Tab UI、ViewModel、二维码渲染、启动编排
  tests/AirMicHub.Tests/  单元测试 + 进程内真实 Kestrel WSS/WS 集成测试
```

依赖方向：`App → Server/Audio/Platform/Lyrics → Core`，`Core` 不依赖 UI/NAudio，便于测试。

## 3. 关键实现决策

1. **混音采用拉模型**：`MixEngine` 由 `WasapiOut` 的输出线程按 5 ms 块拉取，不走“定时器写 BufferedWaveProvider”，避免定时器抖动累积延迟。每路 10 ms 预缓冲、30 ms 上限、超限丢最旧，`1/sqrt(n)` 归一化 + 硬限幅。
2. **输出格式自适应**：内部统一 48 kHz / Float32 / Stereo，按设备 mix format（采样率/位深）用 Catmull-Rom 重采样并编码，杜绝 `WasapiOut` 共享模式格式不匹配的坑。
3. **8765 协议完全兼容现有 `phone.html` / `pcm-worklet.js`**：不改 JS 逻辑，仅把文案 “Mac” 改为“电脑”；服务端实现 hello/ready/stats/ping/pong/bye、8 路上限、二进制 Int16LE 单声道 5 ms 帧。
4. **8787 复用 WebAssets 播放器逻辑**：保留 300 ms 目标缓冲 / 500 ms 上限 / 150 ms 下限与 `int16le` 高效模式；只改文案并增加应用层 `ping→pong` 心跳（浏览器自动回 pong，防止 Safari 空闲断链）。
5. **回授治理**：优先 process loopback 排除本进程；失败时降级为设备 loopback，并在 UI/health 明确提示“监听输出与系统默认输出相同，可能回授”，不静默。
6. **默认输出切换**：`IPolicyConfig`（未公开 COM）修改 + 修改后回读校验；失败时提示手动在系统托盘切换，绝不谎报成功。
7. **可验证性**：服务端、混音、证书、LRCLIB/LRC 均可无 UI 测试；App 提供 `--headless`（只跑服务与音频，供集成测试）与 `--render-ui`（离屏渲染 UI 截图）诊断参数。

## 4. 里程碑与验收

- **M1 骨架与设备**：WPF 三 Tab 深色 UI；输入/输出设备枚举；本机麦克风 → 选定输出；测试音；二维码/URL。
- **M2 8765 手机麦克风**：HTTPS/WSS、自签证书、8 路、队列/混音、stats/ping、/health。
- **M3 8787 系统声音**：loopback/process loopback、WS 广播、多设备去重、300 ms 缓冲、高效模式。
- **M4 K 歌**：平台按钮、GSMTC、LRCLIB/LRC、歌词时钟/偏移、统一输出、原唱限制说明。
- **M5 打包验收**：self-contained win-x64 单文件发布、build.ps1、README、TEST_REPORT、zip。

每个里程碑完成后：`dotnet build` + 对应测试全部通过，才进入下一个。

## 5. 风险与取舍

| 风险 | 处理 |
|---|---|
| process loopback COM 互操作在部分机器失败 | try/catch + 自动降级设备 loopback；captureMode 暴露到 /health 和 UI |
| 设备 mix format 非 48k float | 自研重采样 + 多格式编码；启动时读取 mix format 校验 |
| iPhone Safari 后台/锁屏暂停麦克风 | 页面保留原提示；README 说明保持前台 |
| 默认输出切换 API 随系统更新失效 | 回读校验 + 失败提示，不阻断人声监听 |
| 多网卡/VPN 选错 IP | 刷新网卡列表，UI 可切换；证书按当前 IP 重新生成并重启监听 |
| 单文件发布下 web 资源丢失 | 资源以 EmbeddedResource 嵌入，同时复制到 `web/` 便于排查 |
| 无声卡/无声环境（CI） | 混音核心可空输出运行，stats 照常；集成测试不依赖物理设备 |

## 6. 明确不做（与任务书 §4 一致）

不做第三方平台抓流/原唱开关、不模拟 iPhone 连续互通、不做云端上传/遥测、8787 不作为 K 歌实时伴奏链路。
