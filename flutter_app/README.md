# 基金雷达 Flutter iOS 版

这是基金雷达的 Flutter iOS App。App 内部加载 GitHub Pages 上的纯前端分析面板，不依赖本地 Python 后端。

## GitHub Actions 自动打包

推送到 `main` 后，仓库会自动运行：

```sh
flutter build ios --release --no-codesign
```

并把 `Runner.app` 打包成：

```text
fund-lens-unsigned.ipa
```

下载位置：

1. 打开 GitHub 仓库。
2. 点 `Actions`。
3. 点最新的 `Build Flutter iOS IPA`。
4. 在页面底部 `Artifacts` 下载 `fund-lens-ios-unsigned-ipa`。

## 重要说明

这个 `.ipa` 是未签名包。iPhone 不能直接安装未签名 IPA，需要你自己用 Sideloadly、AltStore、TrollStore、企业签名或自己的 Apple Developer 证书重新签名后安装。

App 默认打开：

```text
https://haode9344-ui.github.io/fund-lens/
```

分析逻辑仍然只作为辅助参考，不构成投资建议。
