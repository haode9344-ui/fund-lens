# 用 GitHub 部署 Fund Lens

可以用 GitHub，但 GitHub 本身主要负责保存代码。Fund Lens 需要 Python 后端上网抓基金数据，所以推荐：

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

不建议只用 GitHub Pages。GitHub Pages 只能放静态页面，不能稳定运行 Python 后端，也不能替你实时抓基金净值、重仓股和股票行情。
