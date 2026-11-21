# -*- coding: utf-8 -*-
"""Copy reference web assets into the Windows app, changing only user-facing copy."""
import pathlib

root = pathlib.Path(r"C:\Users\chen\Documents\deepseek-harness\default-workspace\windows-app")
ref = pathlib.Path(r"C:\Users\chen\Documents\deepseek-harness\default-workspace\machub-src\MacAudioHub-WindowsPort\macos-reference-source\Resources")
out = root / "src" / "AirMicHub.Server" / "Assets"
out.mkdir(parents=True, exist_ok=True)

phone = (ref / "phone.html").read_text(encoding="utf-8")
replacements = {
    "Mac 在线": "电脑在线",
    "把手机变成 Mac 的无线麦克风": "把手机变成电脑的无线麦克风",
    "已接入 Mac · 第 ": "已接入电脑 · 第 ",
    "声音已实时同步到 Mac。": "声音已实时同步到电脑。",
    "使用电脑扬声器播放": "使用电脑扬声器播放",
    "使用 Mac 扬声器播放": "使用电脑扬声器播放",
    "连接 Mac 超时，请确认手机和 Mac 在同一 Wi-Fi。": "连接电脑超时，请确认手机和电脑在同一 Wi-Fi。",
    "与 Mac 的连接已断开": "与电脑的连接已断开",
    "无法连接 Mac，请确认二维码地址可以打开。": "无法连接电脑，请确认二维码地址可以打开。",
    "正在等待 Mac 确认音频通道": "正在等待电脑确认音频通道",
    "Mac 未确认音频通道": "电脑未确认音频通道",
    "请确认手机与 Mac 仍在同一 Wi-Fi，然后重试。": "请确认手机与电脑仍在同一 Wi-Fi，然后重试。",
    "请确认手机与 Mac 仍在同一 Wi-Fi。": "请确认手机与电脑仍在同一 Wi-Fi。",
    "无法接入 Mac": "无法接入电脑",
}
for old, new in replacements.items():
    phone = phone.replace(old, new)

stale = [line.strip() for line in phone.splitlines() if "Mac" in line]
(out / "phone.html").write_text(phone, encoding="utf-8")
for name in ("pcm-worklet.js", "manifest.webmanifest", "favicon.svg"):
    (out / name).write_bytes((ref / name).read_bytes())

print("phone.html written; remaining Mac lines:", len(stale))
for line in stale:
    print("  ", line[:160])
