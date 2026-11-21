# Contributing

感谢参与。

## 开发环境

- macOS 14+
- Xcode Command Line Tools
- Apple Silicon（Intel 未测试）

## 构建

```bash
./build.sh
./build.sh --install
```

提交 PR 前请至少确认 `./build.sh` 成功。

## 提交内容

- Bug 修复请附复现步骤、macOS 版本、Mac 型号、手机/iPhone 型号；
- UI 改动请附截图；
- 不要提交用户音频、证书私钥、Apple Account 信息；
- 不要提交 `build/`、`.app`、日志。

## 代码风格

- 尽量保持现有 Swift 风格；
- 新功能优先使用 Apple 公开框架；使用私有 API 时请在 PR 中注明风险；
- 涉及 TCC 权限的改动，请在说明里写清楚首次授权流程。
