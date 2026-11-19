# 快速开始

## 安装

1. 在[首页](/)下载 Apple Silicon 版，解压后把 Lite2D.app 拖进「应用程序」。
2. 打开 Lite2D。应用会出现在屏幕顶部的菜单栏。
3. 如果 macOS 拦截首次启动，先尝试打开一次，再到「系统设置 → 隐私与安全性」找到 Lite2D，选择「仍要打开」。

公开应用包为临时签名，尚未公证。v1.8.0 的主程序部署目标是 macOS 14，已在 Apple Silicon 的 macOS 27.2 上验证，macOS 14 实机兼容性还有待确认。

## 添加角色

点击菜单栏的 Lite2D 图标，选择「添加角色…」，然后选取你有权使用的模型。支持模型 JSON、完整模型文件夹以及兼容的 LPK、WPK 和 ZIP 模型包。请自行准备模型。

从菜单打开「设置…」即可调整角色的位置、大小、动作和互动。你可以添加多个角色，每个角色分别设置。

## 升级与备份

升级前先退出 Lite2D，再用新版本替换「应用程序」里的旧版本。建议先备份整个 `~/Library/Application Support/Lite2D/` 文件夹，其中保存了模型、布局、Persona 和记忆。需要回退时，请恢复与旧版本匹配的备份。

如需核对下载文件的完整性，可以在对应的 [GitHub Release](https://github.com/0x535a/Lite2D/releases) 下载 `SHA256SUMS.txt`。把它与 ZIP 放在同一个目录，在该目录运行 `shasum -a 256 -c SHA256SUMS.txt`。
