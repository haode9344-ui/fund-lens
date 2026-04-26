# Fund Lens iOS 自签说明

当前 Windows 环境不能直接生成可安装 `.ipa` 或执行 Apple 代码签名。这个目录已经整理成 Xcode 工程，你在 Mac 上打开 `FundLens.xcodeproj`，选择自己的 Apple ID Team，就可以自签安装或导出 IPA。

## 最快安装方式

如果只是自己在 iPhone 上用，先用 Safari 打开本机服务地址，然后点“分享”->“添加到主屏幕”。项目已经加了 PWA 配置，会像普通 App 一样从桌面打开。

## Xcode 自签方式

1. Mac 上打开 `FundLens.xcodeproj`。
2. 在 `FundService.swift` 里把 `baseURL` 改成你的服务器地址。如果手机和电脑在同一 Wi-Fi，地址通常是电脑局域网 IP，例如 `http://192.168.1.20:8765`。
3. Signing & Capabilities 里选择你的 Apple ID Team。
4. 连接 iPhone，点击 Run 安装。

## 在 Mac 上导出 IPA

```sh
cd ios
chmod +x build_ipa.sh
TEAM_ID=你的TeamID BUNDLE_ID=com.yourname.FundLens ./build_ipa.sh
```

生成结果会在：

```text
ios/build/export/
```

如果要完全离线原生运行，需要把 Python 后端逻辑改写成 Swift 或部署到你自己的公网服务器。
