# AirMic Hub Windows 版 · 验收测试报告

- 版本：1.0.0
- 测试日期：2026-11-21
- 测试机：Windows 11（10.0.26200），x64，Realtek 扬声器 + 麦克风
- 结论：**M1–M5 全部完成**；自动化测试 34/34 通过；单文件发布、真实 Kestrel 协议、
  混音→输出→回环、进程回环（排除本应用）、8787 二进制广播均已实测通过。
  **未执行**实体手机扫码与第三方音乐平台真人 K 歌（环境无手机/无平台播放），
  已在第 6 节逐项标注替代验证方式。

---

## 0. 里程碑完成情况

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M1 骨架与设备 | ✅ | WPF 三 Tab 深色 UI；输入/输出设备枚举；本机麦克风→选定输出；测试音；二维码/URL |
| M2 8765 手机麦克风 | ✅ | Kestrel HTTPS/WSS；自签证书；复用 phone.html/pcm-worklet.js；hello/ready/stats/ping；8 路混音/队列/输出 |
| M3 8787 系统声音 | ✅ | WASAPI 设备 loopback + 进程回环；HTTP/WS 广播；播放器 300 ms 缓冲；多设备去重；排除本应用 |
| M4 K 歌 | ✅ | 平台按钮、GSMTC、LRCLIB/LRC、歌词时钟/偏移、统一输出、原唱限制说明（真人 K 歌未实测，见 §7） |
| M5 打包与验收 | ✅ | self-contained 单文件 win-x64；build.ps1；README；TEST_REPORT；zip + SHA256；发布版冒烟/解压运行 |

---

## 1. 环境与构建

| 项目 | 值 |
|---|---|
| OS | Windows 11 10.0.26200（x64） |
| .NET SDK | 8.0.426（运行时 8.0.32） |
| 构建命令 | `powershell -File .\build.ps1`（Release） |
| 测试 | `dotnet test` → **34 passed / 0 failed / 0 skipped** |
| 发布 | self-contained、单文件、`PublishSingleFile`、win-x64 |
| 产物 | `dist\AirMicHub\AirMicHub.exe` ≈ 80.6 MiB；`dist\AirMicHub-win-x64-1.0.0.zip` ≈ 75.4 MiB（以实际文件为准） |
| SHA256（zip） | 见 `dist\SHA256SUMS.txt`（zip 内文件随文档更新会变化，故不在报告内写死） |
| 启动耗时 | 发布版 headless 启动并写完状态 **4.6 s**（首次单文件解压） |

### 实测端口说明

测试机上 **8765 已被百度输入法 `BaiduPinyin.exe` 占用**。App 的端口冲突处理按设计生效：

1. 首次绑定 `0.0.0.0:8765` 返回 `address already in use`；
2. 界面/日志给出“端口被占用”错误；
3. 自动回退到 `8766`（麦克风）/ `8788`（音箱），保存到 `settings.json` 并刷新二维码。

因此本报告中的实测 URL 为 `https://192.168.3.123:8766/`、`http://192.168.3.123:8788/`。
在 8765/8787 空闲的机器上会直接使用默认端口。

---

## 2. 自动化测试（34 项）

| 测试组 | 数量 | 覆盖内容 | 结果 |
|---|---|---|---|
| `LrcParserTests` | 5 | 时间戳、多时间戳、排序、纯文本、偏移查找 | 通过 |
| `MixEngineTests` | 7 | 30 ms 队列上限、10 ms 预缓冲、多路归一化、44.1k→48k、测试音、静音、源移除 | 通过 |
| `CertificateManagerTests` | 3 | SAN 覆盖 LAN IP/localhost、持久化复用、IP 变化重建、重置 | 通过 |
| `LyricsServiceTests` | 6 | 同步/纯文本/未匹配/服务失败/搜索/缓存/偏移 | 通过 |
| `MicServerTests` | 5 | 页面/worklet/health、WSS hello→ready→stats、9 台被拒、静音、PCM 入混音 | 通过 |
| `SpeakerServerTests` | 7 | 页面/health、ready、关闭捕获时 start 报错、Int16 状态、设备 ID 去重、start+捕获、同时运行 | 通过 |

测试使用**真实 Kestrel**、真实自签名证书、随机空闲端口和真实 `ClientWebSocket`，
不是 mock HTTP。`dotnet test -c Release` 输出：

```
已通过! - 失败: 0，通过: 34，已跳过: 0，总计: 34
```

---

## 3. 验收项 1：手机麦克风（8765）

| 检查项 | 结果 | 证据 |
|---|---|---|
| 页面与 worklet 可访问 | ✅ | `GET /` 含 `电脑在线`、`pcm-worklet.js`；`GET /pcm-worklet.js` 200，`pcm-processor` 存在 |
| 健康检查 | ✅ | `/health` 返回 `app=AirMic`、`sampleRate=48000`、`phones=0/1`、`engine=true` |
| hello → ready | ✅ | `{"type":"ready","sampleRate":48000,"targetBufferMs":25,"channel":1,"server":"AirMic"}` |
| stats 字段 | ✅ | `bufferMs/queueMs/outputLatencyMs/latencyMs/rttMs/kbps/level/sampleRate/phones/underruns` 全部存在；实测 `bufferMs=35, outputLatencyMs=30, latencyMs=35` |
| 5 ms Int16 PCM 入队 | ✅ | HubProbe 发送 480 字节帧后 `/health` 出现 `sources[0]`，`queueMs=5`，`level=0.4602` |
| 8 路上限 | ✅ | 集成测试：前 8 台分别拿到 channel 1..8；第 9 台收到 `error`（含“上限（8 台）”） |
| 每路静音/电平 | ✅ | `SetMuted` 后 health `muted=true`；UI 每路 chip 显示电平条和静音按钮 |
| 混音→输出设备 | ✅ | 音频自检：向 `MixEngine` 注入 440 Hz，设备回环捕获 RMS **0.04294**（非零），见第 5 节 |
| 端到端延迟 | ⚠️ 协议值 35 ms | 由 `queueMs + outputLatency + rtt/2` 计算；`outputLatency` 为设备流延迟估算（本机 30 ms）。真实手机 RTT 未测 |
| 实体手机扫码/证书/麦克风授权 | ❌ 未执行 | 环境无实体手机；浏览器端页面与协议已由 HubProbe 等价验证 |

---

## 4. 验收项 2：Windows 系统声音 → 手机（8787）

| 检查项 | 结果 | 证据 |
|---|---|---|
| 播放器页面 | ✅ | `GET /` 含 `电脑音箱`、`TARGET_LATENCY_MS = 300`、`/ws` |
| health | ✅ | `app=AirMicSpeaker`、`sampleRate=48000`、`channels=2`、`format=float32le` |
| ready | ✅ | `{"type":"ready","sampleRate":48000,"channels":2,"format":"float32le","deviceId":"..."}` |
| start → state | ✅ | `{"type":"state","playing":true,"format":"float32le"}` |
| 真实系统音频广播 | ✅ | 由**独立进程** HubProbe 播放 440 Hz WAV；手机 WS 收到 **370 个二进制帧 / 1,420,800 字节 / RMS 0.10929** |
| 进程回环排除本应用 | ✅ | `/health` 运行中：`capturing=true, captureMode=process, excludesOwnAudio=true`；音频自检中同一测试音：设备回环 RMS 0.043，进程回环 RMS **0** |
| 高效模式（Int16） | ✅ | 集成测试切到 `int16le` 后客户端收到 `state.format=int16le`，health 同步 |
| 同设备去重 | ✅ | 集成测试：同 `deviceId` 重连，旧连接在 5 s 内收到 close，health 设备数=1 |
| 2 台手机同时收听 | ⚠️ 协议支持、未实测多手机 | 服务端按客户端独立队列广播；测试覆盖多客户端连接/去重，未用两台实体手机验证同步 |
| 音画同步 | ⚠️ 未执行 | 需实体手机与视频；缓冲策略与 macOS 版一致（300/500/150 ms） |

---

## 5. 音频链路实测（`--audio-probe`）

`artifacts/audio-probe.json` 摘要：

```json
{
  "outputStarted": true,
  "outputError": null,
  "outputFormat": "48000 Hz / 2 ch / 32 bit / float",
  "localMicStarted": true,
  "localMicDevice": "麦克风阵列 (UU远程虚拟音频设备)",
  "localMicFrames": 91,
  "deviceLoopback":  { "mode": "loopback", "frames": 36,  "rms": 0.04294 },
  "processLoopback": { "mode": "process",  "frames": 225, "rms": 0.0 },
  "outputSwitchAvailable": true
}
```

解读：

1. 输出设备以 **48 kHz / 双声道 / Float32（WAVEFORMATEXTENSIBLE）** 启动；
2. 本机麦克风成功采集 91 个回调（无权限/设备错误）；
3. 向混音器注入 440 Hz 后，**设备 loopback 捕获到声音**（RMS 0.043），证明
   “混音器 → WasapiOut → 物理输出 → 采集” 链路成立；
4. 同一信号下 **进程回环 RMS = 0**，证明 8787 已正确排除 AirMic Hub 自身，不会把
   本机人声监听回授给手机；
5. `IPolicyConfig` COM 可用（`outputSwitchAvailable=true`）。为避免改动测试机的
   系统默认音频设备，未实际切换；代码在切换后会回读默认设备校验。

---

## 6. 验收项 3：同时运行

| 检查项 | 结果 | 证据 |
|---|---|---|
| 两个服务同时监听 | ✅ | 同一进程监听 `0.0.0.0:8766`（HTTPS/WSS）与 `0.0.0.0:8788`（HTTP/WS） |
| 同时连接 | ✅ | HubProbe 在同一轮内完成 8765 WSS hello/ready/stats 与 8787 ready/start/音频 |
| 互不踢掉 | ✅ | 集成测试 `BothServicesServeAtTheSameTime`；health 两端口均 `ok` |
| CPU/内存 | ✅ 可接受 | 空闲时仅 5 ms 混音拉取 + 1 s 状态轮询；8787 无收听设备时自动停止捕获 |

---

## 7. 验收项 4：K 歌

| 检查项 | 结果 | 证据/说明 |
|---|---|---|
| 平台播放伴奏 | ⚠️ 未实测 | 测试机未运行音乐平台；App 不介入平台播放 |
| 手机麦克风人声从选定音箱输出 | ✅ 间接 | 第 5 节混音→输出链路；UI 输出设备选择与测试音 |
| 一键统一输出 | ⚠️ 未实际切换 | `IPolicyConfig` 可用；实现是“App 输出 + 系统默认输出”，失败会提示手动切换。未改测试机默认设备 |
| Now Playing | ⚠️ 无会话 | GSMTC 启动成功；测试时无平台播放，UI 显示“等待音乐平台播放”，未伪造 |
| 歌词自动匹配 | ⚠️ 网络路径未打通实测 | LRCLIB 客户端已实现并有假提供者单测（同步/纯文本/未匹配/失败/缓存）；未在真实网络命中歌曲 |
| 手动搜索 / 载入 LRC / ±0.5s / 手动时钟 | ✅ 代码 + UI | UI 控件齐全；LRC 解析、偏移、时钟单测通过 |
| 原唱限制说明 | ✅ | K 歌页与 README 明确“只能在平台内切换，不抓流” |

---

## 8. 验收项 5：打包

| 检查项 | 结果 | 证据 |
|---|---|---|
| `dotnet publish` 单文件 | ✅ | `dist\AirMicHub\AirMicHub.exe` = 84,535,389 字节，self-contained |
| 无管理员权限启动 | ✅ | 以普通用户启动发布版 headless，4.6 s 后两个服务健康 |
| zip 解压后可运行 | ✅ | 解压到 `artifacts\zip-test`，运行其中 `AirMicHub.exe`，两个 `/health` 均 `status=ok` |
| 发布版端口/证书/资源 | ✅ | 使用 `%LOCALAPPDATA%` 证书与设置；web 资源嵌入，另有 `Assets/` 松散副本 |
| 另一台 Windows 可运行 | ⚠️ 未实测第二台机器 | self-contained x64；README 写明防火墙与端口要求 |
| zip | ✅ | `dist\AirMicHub-win-x64-1.0.0.zip`（约 75.4 MiB）+ `SHA256SUMS.txt` |

发布版冒烟命令与结果：

```powershell
dist\AirMicHub\AirMicHub.exe --headless --seconds 60 --status-file artifacts\published-status.json
# {"running":true,"micPort":8766,"speakerPort":8788,"error":null,...}
# /health 两个端口均 status=ok
```

---

## 9. UI 回归

`--render-ui` 离屏渲染三页（`docs/screenshots/`）：

- `mic.png`：二维码、URL、连接步骤、延迟/缓冲/音质/码率、电平、音量、输出设备、输入源 chips；
- `karaoke.png`：平台卡片、歌词工具栏与空状态、底部监听条、统一输出按钮；
- `speaker.png`：播放二维码、捕获开关、高效模式、捕获模式、收听设备列表、回授提示。

渲染过程无 XAML 绑定错误、无未处理异常（日志见 `%LOCALAPPDATA%\AirMicHub\logs`）。

---

## 10. 已知问题与未覆盖

1. **实体手机未接入**：扫码、自签名证书警告、iOS/Android 麦克风授权、真实 RTT、
   端到端 < 60 ms 的听感未验证；协议层已用 WSS 等价验证。
2. **多手机同步**：服务端广播按客户端独立队列，未用两台实体手机测同步；浏览器端
   300 ms 缓冲逻辑沿用参考实现。
3. **K 歌真人测试未做**：无平台播放、无真人演唱；GSMTC/歌词/统一输出代码路径已实现。
4. **默认输出切换未实际执行**：仅验证 COM 可用，避免改动测试机设置；失败提示逻辑已实现。
5. **8765 端口冲突**：测试机被百度输入法占用，自动回退到 8766/8788；这是真实环境
   验证，但也意味着本机报告里的 URL 与默认文档不同。
6. **防火墙/跨机**：未在第二台机器验证；README 给出专用网络放行步骤。
7. **蓝牙、采样率非 48k、设备热插拔**：输出设备回退有 watchdog 逻辑，但未逐一实测。

---

## 11. 本轮代码审查与修复（2026-11-21 晚）

在交付前做了一轮并发/资源/状态一致性审查，修复如下：

| 问题 | 修复 |
|---|---|
| `--capture-mode` 只影响音频探针，普通运行仍用 `auto` | 参数同时写入 `Settings.CaptureMode`；实测 `captureMode=loopback` |
| 切换输出设备/统一输出时，即使 `WasapiOut` 启动失败也提示成功 | 检查 `Output.IsRunning`，失败时返回真实错误且不修改系统默认输出 |
| UI 每 200 ms 枚举声卡取设备名，COM 压力大 | 设备名/默认端点改为 5 s 缓存，切换设备时强制刷新 |
| 进程回环运行中失败后 health 仍显示 `capturing=true` | 失败时置 `idle`、记录错误并通过 `StateChanged/ErrorChanged` 通知 |
| 输出设备拔出触发 `PlaybackStopped` 后不再恢复 | watchdog 捕获意外停止，自动回退系统默认设备并提示 |
| 歌词自动匹配的旧请求晚到，覆盖新歌歌词 | 增加请求版本号，过期结果直接丢弃（新增单测） |
| 手动 LRC/搜索与旧歌词行数相同、当前行相同时 UI 不刷新 | 增加内容签名（来源/状态/首尾行）触发重建 |
| 手动载入 LRC 后偏移没有归零 | `LoadLrcText` 统一重置偏移 |
| 纯文本歌词会错误高亮最后一行 | 纯文本不计算当前行，只平铺显示 |
| 输出启动失败时 `WasapiOut`/设备对象泄漏 | catch 中显式解绑事件并释放 |
| 证书重新生成时旧 `X509Certificate2` 未释放 | 替换/重置时释放旧证书 |
| 8787 发送 `ready` 失败时客户端残留在列表 | 失败立即移除客户端 |
| 关闭捕获与“进程回环启动中”竞争，可能继续捕获 | 启动完成后复查 `CaptureEnabled/Listening`，必要时立即停止 |

修复后：**34/34 测试通过**，音频探针、8787 外部音源探针、UI 渲染、发布版冒烟均重新验证通过。

---

## 12. 复现命令

```powershell
# 1. 构建 + 测试 + 打包
.\build.ps1

# 2. 只跑测试
dotnet test tests\AirMicHub.Tests\AirMicHub.Tests.csproj -c Release

# 3. 发布版冒烟（先清空/备份 settings.json 可回到默认端口）
dist\AirMicHub\AirMicHub.exe --headless --seconds 30 --status-file artifacts\headless-status.json

# 4. 音频链路自检
dist\AirMicHub\AirMicHub.exe --audio-probe --probe-seconds 2 --probe-out artifacts\audio-probe.json

# 5. 协议 + 8787 真音频探针（需要 App 正在运行；读取其端口）
dotnet run --project tools\HubProbe -- --mic https://127.0.0.1:8766 --speaker http://127.0.0.1:8788 --play-tone

# 6. UI 截图
dist\AirMicHub\AirMicHub.exe --render-ui artifacts\ui
```

