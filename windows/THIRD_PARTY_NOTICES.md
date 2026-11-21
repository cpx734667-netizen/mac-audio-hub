# 第三方组件与许可

AirMic Hub（Windows 版）以 MIT 许可发布。以下组件随程序或源码使用：

| 组件 | 版本 | 许可 | 用途 |
|---|---|---|---|
| [NAudio](https://github.com/naudio/NAudio) | 2.2.1 | MIT | WASAPI 设备枚举、采集、loopback、输出 |
| [QRCoder](https://github.com/codebude/QRCoder) | 1.6.0 | MIT | 二维码生成（PNG，无 GDI+ 依赖） |
| [.NET 8 / ASP.NET Core](https://github.com/dotnet) | 8.0 | MIT | 运行时、WPF、Kestrel |
| [macOS 参考项目](https://github.com/cpx734667-netizen/mac-audio-hub) | commit a59bab2 | MIT | 产品行为、协议、手机页面与播放器 JS 的参考实现 |
| [LRCLIB](https://lrclib.net/) | API | 社区歌词服务 | 按歌名/歌手查询同步歌词；仅发送元数据 |

## 字体与图标

- UI 使用 Windows 自带的 Segoe UI / Microsoft YaHei UI；
- 二维码、矢量图标由本项目生成或使用几何图形绘制；
- 应用图标由 `tools/make_icon.py` 生成，无第三方素材。

## 参考页面

`src/AirMicHub.Server/Assets/phone.html`、`pcm-worklet.js`、`manifest.webmanifest`、
`favicon.svg` 来自 macOS 参考项目的 `Resources/`（MIT），仅修改了面向用户的
“Mac”文案为“电脑”，音频协议与帧格式未改动。`speaker.html` 复用了参考项目
`Sources/MacSpeaker/WebAssets.swift` 中的播放器逻辑（MIT），并增加应用层心跳。
