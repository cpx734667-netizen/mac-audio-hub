# AirMic Hub（Windows 原生版）

把手机变成 Windows 麦克风，把 Windows 系统声音送到手机，并给家庭 K 歌提供一个统一的
人声监听 + 歌词 companion。两个服务（8765 / 8787）在同一个进程里同时运行。

这是 macOS「Mac 音频枢纽 / AirMic Hub」的 Windows 原生移植：音频栈、证书、设备管理、
服务端全部用 C# / .NET 8 + WPF + Kestrel + NAudio 重写，浏览器端协议保持兼容。

> 版本 1.0.0 · Windows 10 2004+ / Windows 11 · x64 · 无需管理员权限

![手机麦克风页](docs/screenshots/mic.png)

---

## 1. 功能

- **手机麦克风（8765，HTTPS/WSS）**
  - 手机扫码打开页面，最多 **8 台手机**同时接入，自动分配第 1..8 路；
  - 手机以 5 ms / Int16LE / 单声道 PCM 推流；服务端统一重采样到 48 kHz；
  - 和本机麦克风、USB 麦克风、耳机麦克风一起混音，输出到指定 Windows 音箱；
  - 每路 10 ms 预缓冲、30 ms 上限，超限丢最旧帧，不累积延迟；
  - 手机页面显示连接状态、路数、延迟、电平、增益；桌面端显示每路电平并可单独静音。
- **Windows 系统声音 → 手机（8787，HTTP/WS）**
  - WASAPI loopback 捕获 Windows 正在播放的声音；
  - 优先使用**进程回环**并排除 AirMic Hub 自身，避免把本机人声监听回授给手机；
  - 手机端约 **300 ms** 目标缓冲，多台手机同步；高效模式使用 Int16LE；
  - 同一手机重复连接自动踢旧连接，不会双声。
- **K 歌页**
  - 平台（网易云 / QQ 音乐 / 酷狗）在桌面正常播放伴奏，App 只做人声监听；
  - 一键「统一音乐与人声」：App 人声输出 + Windows 默认输出切到同一个音箱；
  - GSMTC 读取系统 Now Playing，LRCLIB 自动匹配歌词，支持手动搜索、载入 `.lrc`、±0.5 s 偏移和手动歌词时钟；
  - 明确提示：原唱/伴奏只能在平台 App 内切换，第三方没有公开接口。

---

## 2. 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 2004（build 19041）及以上，或 Windows 11；x64 |
| 运行时 | 发布包为 **self-contained**，目标机无需安装 .NET |
| 权限 | 普通用户即可运行；首次监听端口时 Windows 可能弹出防火墙提示 |
| 网络 | 手机和电脑在同一 Wi-Fi / 局域网；部分公司、酒店 Wi-Fi 会隔离设备 |
| 浏览器 | iPhone Safari / Android Chrome / Edge 等现代浏览器；手机麦克风页必须是 `https://` |

---

## 3. 快速开始

1. 解压 `AirMicHub-win-x64-1.0.0.zip`，双击 `AirMicHub.exe`。
2. 如果 Windows 防火墙弹窗，勾选 **专用网络** 并允许（8765 / 8787 入站）。
3. 打开 **麦克风** 页：
   - 用手机相机扫描左侧二维码，或手动输入 `https://<电脑IP>:8765/`；
   - 首次会提示证书不受信任 —— 这是自签名证书，选择「继续访问 / 高级 → 继续前往」；
   - 在手机上点「开始传音」并允许麦克风，保持页面在前台。
4. 在桌面右下角选择人声输出设备，点「测试当前输出」确认声音从正确的音箱出来。
5. 打开 **音箱** 页，手机扫码 `http://<电脑IP>:8787/`，点「开始播放」即可收听电脑声音。

> 手机锁屏或切到后台时，浏览器会暂停麦克风；请让手机页面保持在前台。

---

## 4. 三个页面

### 4.1 麦克风

- 左侧：二维码、地址、复制按钮、三步连接说明。
- 右侧：端到端延迟、抖动缓冲、音质、实时码率、输入电平、播放音量、输出设备选择、
  测试音、声音设置。
- 底部：输入源。本机麦克风开关 + 输入设备选择；每台手机显示第 N 路、名字、电平、
  静音按钮。活动手机与本地麦克风可同时混音。

### 4.2 音箱

- 左侧：播放二维码 / 地址 / 步骤 / 300 ms 缓冲说明。
- 右侧：捕获状态、允许手机收听开关、高效模式（Int16LE）、采样率/声道/格式/码率、
  收听设备列表、捕获错误与回授提示。
- 捕获只在至少一台手机点「开始播放」时启动，没有收听设备时自动停止，节省 CPU 和隐私风险。

### 4.3 K 歌

- 左侧：当前平台歌曲（标题/歌手/专辑/进度/播放控制）、打开平台按钮、原唱限制说明。
- 右侧：歌词工具栏（开始歌词、±0.5 s、归零、搜索、载入 LRC）、当前行高亮歌词。
- 底部：人声监听状态、手机二维码、麦克风设置、测试输出、统一输出。
- 「统一音乐与人声」会同时修改 App 人声输出与 Windows 默认输出；如果 Windows 拒绝自动
  切换，会明确提示你手动在「声音设置」中选同一个音箱，不会谎报成功。

---

## 5. 端口、证书与网络

### 5.1 端口

- 默认：麦克风 `8765`（HTTPS/WSS），音箱 `8787`（HTTP/WS）。
- 如果启动时端口被占用（例如输入法、远程工具、旧实例），App 会：
  1. 在界面上显示具体错误；
  2. **自动尝试下一对可用端口**（如 8766 / 8788），保存到设置并刷新二维码，同时弹出提示。
- 手动指定端口：

```powershell
.\AirMicHub.exe --port-mic 9000 --port-speaker 9001
```

或编辑 `%LOCALAPPDATA%\AirMicHub\settings.json` 的 `micPort` / `speakerPort`。

### 5.2 自签名证书

- 首次启动生成 RSA 2048 自签名证书，SAN 包含 `localhost`、当前所有 LAN IPv4、本机名；
- 保存在 `%LOCALAPPDATA%\AirMicHub\cert.pfx`，私钥用 **DPAPI（当前用户）** 加密；
- 有效期 1 年；LAN IP 变化时自动重新生成并重启监听；
- 不会把证书装进 Windows 信任库；手机浏览器警告是预期行为；
- 证书损坏或想重置：

```powershell
.\AirMicHub.exe --reset-cert
```

删除 `%LOCALAPPDATA%\AirMicHub\cert.pfx` 后重启也可以。

### 5.3 防火墙

- 首次监听时允许 **专用网络** 的 8765、8787 入站；
- 如果手机打不开页面：
  - 确认手机和电脑在同一网段；
  - 在桌面页脚切换「二维码网卡」（多网卡 / VPN / 虚拟网卡时尤其重要）；
  - 检查 Windows Defender 防火墙是否拦截了 `AirMicHub.exe`；
  - 公司/酒店 Wi-Fi 可能启用客户端隔离，需要换网络或开热点。

### 5.4 多网卡 / VPN

桌面页脚提供「二维码网卡」下拉框，可选「自动选择」或指定某个 IPv4。优先级：
有默认网关的以太网/Wi-Fi > 其他物理网卡 > 虚拟网卡 > VPN。切换后二维码和证书会刷新。

---

## 6. 音频设备与延迟

- **输出设备**：桌面「麦克风」页选择；测试音从当前选中设备播放，用于确认「听到的就是选中的音箱」。
- **本机麦克风**：底部输入源开关；可选择默认输入或具体设备。
- **内部格式**：48 kHz / Float32 / Stereo；按输出设备的混音格式重采样并编码，
  支持 Float32 与 16/24/32-bit PCM（WAVEFORMATEXTENSIBLE 也会正确识别）。
- **监听延迟**：WASAPI 20 ms 缓冲 + 设备流延迟（通常 30 ms 左右）；手机端端到端目标 < 60 ms。
- **蓝牙**：A2DP 会增加 80–200 ms 延迟，K 歌建议内置扬声器或有线耳机。
- **不要用 8787 当 K 歌实时伴奏**：它有约 300 ms 同步缓冲，只适合听歌/看视频。

---

## 7. 歌词与 Now Playing

- Now Playing 通过 Windows GSMTC 读取（网易云/QQ 音乐/酷狗等在系统媒体控制中暴露的会话）；
  平台不暴露时显示「等待音乐平台播放」，不伪造数据。
- 自动歌词：LRCLIB `api/get`，失败后 `api/search`；只发送歌名/歌手/专辑/时长。
- 歌词时钟：
  - 平台提供播放位置时，歌词自动跟随（「歌词时钟：跟随平台」）；
  - 平台不提供位置时，点「开始歌词」用本地计时器（「手动计时」），可 ±0.5 s 微调。
- 支持 `.lrc`（UTF-8 / 带 BOM）和纯文本歌词。纯文本只显示、不滚动。
- **原唱/伴奏**：第三方音乐平台没有公开的原唱切换 API，App 不抓流、不注入 UI；
  请在平台播放器内切换原唱/伴奏或选择伴唱版本。

---

## 8. 已知限制（与 macOS 版差异）

详见 [docs/DIFFERENCES.md](docs/DIFFERENCES.md)，要点：

- **iPhone 连续互通麦克风是 macOS 独占**。Windows 版只支持普通 Windows 输入设备和
  浏览器手机麦克风，不伪造 Continuity。
- macOS 用 ScreenCaptureKit；Windows 用 WASAPI loopback + 进程回环（排除本应用）。
  系统/驱动不支持进程回环时自动降级为设备回环，并在 UI / `/health` 标出。
- Windows 默认输出切换没有稳定的公开 API，使用未公开的 `IPolicyConfig`，系统更新后可能失效；
  失败会提示手动切换。
- 8787 的 300 ms 缓冲与 macOS 一致，不适合实时 K 歌伴奏。
- 不提供平台原唱开关；不做第三方平台抓流/歌词接口逆向。

---

## 9. 故障排查

| 现象 | 处理 |
|---|---|
| 端口被占用，服务未启动 | 关闭占用 8765/8787 的程序，或让 App 自动换端口；也可用 `--port-mic/--port-speaker` |
| 手机打不开页面 | 确认同一 Wi-Fi、二维码网卡正确、防火墙允许专用网络、未开启 AP 隔离 |
| 手机提示证书不受信任 | 正常现象：选择「继续访问」；地址必须是 `https://` 且与证书 SAN 的 IP 一致 |
| 手机没有声音/传音按钮无效 | 允许浏览器麦克风权限；关闭占用麦克风的 App；保持页面在前台 |
| 电脑听不到手机 | 检查输出设备、播放音量、每路静音状态；点「测试当前输出」 |
| 8787 手机没有声音 | 手机点「开始播放」；检查捕获状态/错误；Windows 需正在播放声音 |
| 8787 听到自己的人声 | 说明进程回环不可用且监听输出=系统默认输出；换监听设备为耳机，或查看 `/health` 的 captureMode |
| 歌词不同步 | 用「开始歌词」手动计时，或 ±0.5 s 调整；纯文本歌词不能滚动 |
| 统一输出失败 | 在 Windows「设置 → 系统 → 声音」手动把默认输出设为同一个音箱 |
| 界面没有二维码/网卡 | 电脑没有局域网 IPv4；连接 Wi-Fi/网线，或在页脚切换网卡 |
| 需要日志 | 界面右上角「⋯」打开日志目录；`%LOCALAPPDATA%\AirMicHub\logs` |

健康检查：`https://<IP>:8765/health`、`http://<IP>:8787/health`（含队列、延迟、捕获模式等）。

---

## 10. 构建与测试

环境：.NET SDK 8（`dotnet --version` 应为 8.x），Windows x64。

```powershell
# Release：还原 → 编译 → 34 个测试 → self-contained 单文件发布 → zip
.\build.ps1

# 快速迭代，不打包
.\build.ps1 -Configuration Debug -SkipTests -NoZip

# 依赖框架的较小发布（目标机需安装 .NET 8 Desktop Runtime）
.\build.ps1 -FrameworkDependent
```

产物：

```
dist\AirMicHub\AirMicHub.exe           # 单文件，自包含
dist\AirMicHub-win-x64-1.0.0.zip       # 发布包
dist\SHA256SUMS.txt
```

脚本参数：`-Configuration`、`-Runtime`、`-SkipTests`、`-FrameworkDependent`、`-NoZip`。

### 诊断参数

| 参数 | 作用 |
|---|---|
| `--headless --seconds N --status-file PATH` | 不显示窗口，只启动两个服务，写运行状态 JSON；用于自动化冒烟 |
| `--audio-probe --probe-out PATH` | 枚举设备、启动本机麦克风、输出测试音并用回环捕获验证混音链路 |
| `--render-ui DIR` | 离屏渲染三个 Tab 为 PNG，用于文档/回归 |
| `--reset-cert` | 删除本地证书 |
| `--port-mic N` / `--port-speaker N` | 覆盖端口 |
| `--capture-mode auto\|process\|loopback` | 指定 8787 捕获方式 |

测试项目包含 LRC 解析、重采样/队列/混音、证书 SAN/持久化、LRCLIB 歌词服务（假提供者），
以及**真实 Kestrel** 上的 8765 WSS / 8787 WS 集成测试（hello/ready/stats、8 路上限、
静音、设备去重、两种服务同时运行）。

---

## 11. 目录结构

```
windows-app/
  AirMicHub.sln
  build.ps1
  README.md
  TEST_REPORT.md
  LICENSE / THIRD_PARTY_NOTICES.md
  docs/
    PORT_PLAN.md          # 移植计划与取舍
    DIFFERENCES.md        # 与 macOS 版差异
    screenshots/          # 三页 UI 截图
  src/
    AirMicHub.Core/       # 协议、PCM/重采样、混音、状态、证书、设置
    AirMicHub.Audio/      # NAudio WASAPI：设备、本机麦克风、输出、loopback / 进程回环
    AirMicHub.Server/     # Kestrel 双监听、8765/8787 Hub、内嵌 web 资源
    AirMicHub.Lyrics/     # LRCLIB + LRC 服务
    AirMicHub.Platform/   # GSMTC、平台启动、默认输出切换
    AirMicHub.App/        # WPF 三 Tab UI
  tests/AirMicHub.Tests/  # 34 个单元 + 集成测试
  tools/                  # 资产同步、音频/协议探针、图标生成（不参与发布）
```

浏览器页面：`src/AirMicHub.Server/Assets/phone.html`、`pcm-worklet.js`（由参考实现复制，
仅把文案中的 “Mac” 改为“电脑”，协议未改）；`speaker.html` 复用 8787 播放器逻辑并增加
应用层 `ping→pong` 心跳。

---

## 12. 隐私

- 音频只在局域网内传输，不经过云端；无账号、无遥测、无广告。
- 歌词匹配会向 `lrclib.net` 发送歌名、歌手、专辑、时长（不含音频）。
- 平台按钮只负责打开已安装的客户端，不读取平台数据、不注入界面。
- 日志只记录设备名、端口、错误等技术信息，不记录音频内容。

---

## 13. 许可证

MIT。参考的 macOS 项目亦为 MIT（Copyright (c) 2026 cpx）。第三方组件见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

