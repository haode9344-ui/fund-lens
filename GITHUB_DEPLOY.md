# 用 GitHub 部署 Fund Lens

可以只用 GitHub Pages。现在前端已经支持纯网页模式，会直接读取东方财富/天天基金公开脚本数据，不需要 Python 后端也能做基础分析。

## 只用 GitHub Pages

1. 打开 GitHub 仓库 `haode9344-ui/fund-lens`。
2. 进入 `Settings`。
3. 左侧点 `Pages`。
4. `Build and deployment` 里选择：

```text
Source: Deploy from a branch
Branch: main
Folder: / (root)
```

5. 点 `Save`。
6. 等 1-3 分钟，GitHub 会给你一个网址，通常是：

```text
https://haode9344-ui.github.io/fund-lens/
```

7. iPhone Safari 打开这个网址，再点“分享”->“添加到主屏幕”。

## GitHub Pages 的限制

- 纯 GitHub Pages 不能运行 Python 后端。
- 基金净值预测、移动平均线、波动率、近几日复盘、明天涨跌分析可以用。
- 重仓股/实时行情如果被数据源限制，可能会显示不完整。
- 新闻舆情和 7x24 预警推送需要云端后端定时运行，GitHub Pages 不能后台监控。

如果想数据更稳定，推荐：

```text
GitHub 仓库 -> Render 自动部署 -> iPhone Safari 添加到主屏幕
```

## 第一步：上传到 GitHub

1. 打开 GitHub。
2. 新建仓库，例如 `fund-lens`。
3. 把这个项目文件夹里的代码上传到仓库。

需要上传的主要文件：

```text
app.py
static/
requirements.txt
Procfile
render.yaml
README.md
DEPLOY.md
```

## 第二步：Render 连接 GitHub

1. 打开 Render。
2. 点击 `New +`。
3. 选择 `Web Service`。
4. 连接你的 GitHub 仓库 `fund-lens`。
5. Render 会自动读取 `render.yaml`。
6. 点击 Deploy。

部署完成后，Render 会给你一个公网地址，例如：

```text
https://fund-lens.onrender.com
```

## 第三步：添加到 iPhone 主屏幕

1. iPhone 用 Safari 打开 Render 给你的网址。
2. 点底部分享按钮。
3. 选择“添加到主屏幕”。
4. 桌面会出现 Fund Lens 图标。

这样电脑关机后，手机也能继续用。

## GitHub Pages 可以吗？

可以。现在已经兼容 GitHub Pages。只是它没有后端，稳定性比 Render 云端版弱一点。
