# 第三方依赖与许可

- [Cubism Native Samples](https://github.com/Live2D/CubismNativeSamples) 与 [Framework](https://github.com/Live2D/CubismNativeFramework)：使用官方 submodule，版权归 Live2D Inc.，适用上游 LICENSE / NOTICE 及 Live2D Open Software License。不要把它们描述为 MIT。
- Cubism Core：Live2D Proprietary Software License，官方 [Native SDK 下载](https://www.live2d.com/en/sdk/download/native/)。本仓库不提交或公开发布专有二进制。
- GLEW / GLFW / stb_image：官方 Sample 的第三方依赖，各自许可见其源码；下载/生成目录不提交。
- 首批个人测试模型来自已安装 Live2DViewerEX 的工坊资源，作者及来源信息保留在原始 config.json。资源仅本机测试，不提交或再分发；订阅或解包不赋予再发布权。
- 旧版 Cubism 2 使用本机已有 `Live2D 2.1.00_1` JavaScript 运行库，以独立 JavaScriptCore VM 执行，原生 OpenGL 提供绘制 API。该运行库为 Live2D 专有内容，保持本地、记录来源及 SHA，不随源码再分发。旧版 SDK 的许可和现代 Core 的许可需分别考虑；不宣称 Cubism 5 Core 可以直接兼容旧模型。

个人开发许可不等于发行许可。该应用可导入不定数量模型，可能属于 [Expandable Application](https://www.live2d.com/en/sdk/license/expandable/)，公开发行前应向 Live2D 核实并完成相应协议。源码、Core、模型各自的许可不能互相替代。

宿主复用 Framework 的公共 API，NativeHost 的资源加载和更新流程参照官方 Minimum Demo；依赖中的版权与许可仍适用。`scripts/isolate_gl_contexts.py` 仅生成 GL 资源单例按 context 隔离的构建副本，不改变模型解码、物理或蒙版算法。
