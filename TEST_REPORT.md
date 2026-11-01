# 验证记录

最后更新：2026-11-01。

## 范围变更

用户指定普通版 Bilibili 22娘 / BiliBili33娘作为首批测试模型。这覆盖原需求“不支持旧版 .moc”的限制：增加旧版运行时支持，同时保留 Cubism Native `.moc3`、一个进程、至少三个独立模型实例等原要求。禁止浏览器宿主、WebView 和额外常驻服务的约束不变。

## M0 环境与依赖（官方 Demo 已通过）

已验证：

- macOS / 架构 / Xcode / clang++ / CMake 实际环境。
- Swift AppKit + OpenGL 模块编译及执行，Exit 0。
- 三屏布局及负坐标：主屏 (0,0)，内屏 (1920,-779)，竖屏 (-1080,-625)，backing scale 均为 2。
- 官方 Samples / Framework 固定到 R5 对应 commit。
- GLEW / GLFW 官方脚本下载完成，Exit 0。
- 本机 13 个工坊资源：7 个 `.moc3`、4 个 `.moc`、2 个非 Cubism。检查描述及二进制魔数，并未实测渲染。
- 首批两模型的本机旧版资源副本存在；22娘含多个动作/皮肤，33娘未声明动作和物理。

后续依赖与兼容性验证：

- 用户已授权 SDK 许可，官方 R5 Core 已安装。SDK ZIP SHA-256：`7ff3a4bbc19c0a8728965aa522ab77eb11b252916453e68a8a78d3b71188bb12`。Core 自报版本 6.0.1。
- 官方 Minimum Demo configure/build 均 Exit 0，97 个构建步骤；`file` 确认为 arm64。
- 使用 `python3 scripts/probe_official_demo.py` 在程序内部捕获 GPU framebuffer，无桌面截图/输入自动化。90 帧运行正常退出。第 15/75 帧分别有 469015 / 453646 个非黑像素，GL error=0；帧 SHA 不同，捕获图确认完整 Hiyori 模型和纹理。日志 `.local/verification/official/`。
- `xcrun swift Tests/LegacyCPUProbe.swift` Exit 0：22/33娘分别以独立 JavaScriptCore context 成功通过已有旧版运行库加载，canvas 均 1000×1200，首个 drawable 分别 18/8 个坐标，SDK error=0。这仅验证 CPU 模型数据，不代表旧版 GPU 渲染通过。
- 旧版运行时技术验证；Cubism 5 Core 不支持 `.moc`，不能假定已兼容。

## M1–M5

尚未完成。F01–F24 均未验收；0–4 实例性能、30 次增删、20 次替换、5 分钟静止及 2 分钟鼠标负载均未测量。无 `.app` 交付物。后续记录必须包含实际命令、Exit Code、场景与数据，不能用计划代替结果。
