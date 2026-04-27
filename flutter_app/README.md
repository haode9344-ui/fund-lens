# 小又 Flutter iOS 版

这是小又的 Flutter iOS App。它提供「持有持仓」和「模拟持仓」两个页面，可以添加基金、录入金额、下拉刷新，并查看今日估算收益、明日趋势、买卖建议、重仓股和公告影响。

## GitHub Actions 自动打包

推送到 `main` 后，仓库会自动运行：

```sh
flutter build ios --release --no-codesign
```

并把 `Runner.app` 打包成：

```text
xiaoyou-unsigned.ipa
```

下载位置：

1. 打开 GitHub 仓库。
2. 点 `Actions`。
3. 点最新的 `Build Flutter iOS IPA`。
4. 在页面底部 `Artifacts` 下载 `xiaoyou-ios-unsigned-ipa`。

## 重要说明

这个 `.ipa` 是未签名包。iPhone 不能直接安装未签名 IPA，需要你自己用 Sideloadly、AltStore、TrollStore、企业签名或自己的 Apple Developer 证书重新签名后安装。

分析逻辑仍然只作为辅助参考，不构成投资建议。
