# 电脑关机后手机也能用的方法

当前本地版地址类似：

```text
http://100.66.62.20:8765
```

这个地址依赖你的电脑开机。电脑关机后，手机就找不到服务。

要让 iPhone 在电脑关机后也能用，需要把 Fund Lens 部署到云端。部署后你会得到一个公网地址，例如：

```text
https://fund-lens.onrender.com
```

iPhone Safari 打开这个公网地址，再点“分享”->“添加到主屏幕”，之后电脑关机也能用。

## 推荐：Render 部署

1. 注册或登录 Render。
2. 新建 `Web Service`。
3. 连接这个项目的 GitHub 仓库，或上传项目代码。
4. Render 会识别 `render.yaml`。
5. 部署完成后，打开 Render 给你的公网地址。
6. 用 iPhone Safari 打开公网地址并“添加到主屏幕”。

## GitHub Pages 接入后端

GitHub Pages 只能托管前端，新闻监控和公告抓取需要连接 HTTPS 后端。

默认会尝试连接：

```text
https://fund-lens.onrender.com
```

如果 Render 给你的地址不是这个，在 GitHub Pages 地址后面加 `api` 参数：

```text
https://haode9344-ui.github.io/fund-lens/?fundCode=161725&api=https://你的后端地址
```

第一次填入后，浏览器会记住这个后端地址。要清除配置，用：

```text
https://haode9344-ui.github.io/fund-lens/?api=clear
```

注意：GitHub Pages 是 HTTPS 页面，不能连接 `http://127.0.0.1:8765` 这种 HTTP 本地后端。

## 重要说明

- 免费云服务可能会休眠，第一次打开会慢一点。
- 如果你要稳定长期用，建议换付费云服务器或自己的服务器。
- 当前 App 分析数据来自东方财富/天天基金公开页面，云端能联网即可正常抓取。
- 这个工具只做辅助分析，不保证基金未来涨跌。
