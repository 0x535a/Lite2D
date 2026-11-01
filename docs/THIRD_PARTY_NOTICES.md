# 第三方依赖与许可

- [Cubism Native Samples](https://github.com/Live2D/CubismNativeSamples) 与 [Framework](https://github.com/Live2D/CubismNativeFramework)：使用官方 submodule，版权归 Live2D Inc.，适用上游 LICENSE / NOTICE 及 Live2D Open Software License。固定版本见 BUILD.md。不要把它们描述为 MIT。
- Cubism Core：Live2D Proprietary Software License，官方 [Native SDK 下载](https://www.live2d.com/en/sdk/download/native/)。本仓库不提交或公开发布专有二进制。
- GLEW / GLFW / stb_image：官方 Sample 的第三方依赖，各自许可见其源码；下载/生成目录不提交。
- 首批个人测试模型来自已安装 Live2DViewerEX 的工坊资源，作者及来源信息保留在原始 config.json。资源仅本机测试，不提交或再分发；订阅或解包不赋予再发布权。
- 旧版 Cubism 2 使用本机已有 `Live2D 2.1.00_1` JavaScript 运行库，以独立 JavaScriptCore VM 执行，原生 OpenGL 提供绘制 API。该运行库为 Live2D 专有内容，保持本地、记录来源及 SHA，不随源码再分发。旧版 SDK 的许可和现代 Core 的许可需分别考虑；不宣称 Cubism 5 Core 可以直接兼容旧模型。

个人开发许可不等于发行许可。该应用可导入不定数量模型，可能属于 [Expandable Application](https://www.live2d.com/en/sdk/license/expandable/)，公开发行前应向 Live2D 核实并完成相应协议。源码、Core、模型各自的许可不能互相替代。

宿主复用 Framework 的公共 API，NativeHost 的资源加载和更新流程参照官方 Minimum Demo；依赖中的版权与许可仍适用。`scripts/isolate_gl_contexts.py` 仅生成 GL 资源单例按 context 隔离的构建副本，不改变模型解码、物理或蒙版算法。

## 自有代码与公开边界

项目原创代码与原创图标资源按根目录 `LICENSE` 的 MIT 条款提供。该许可不覆盖 `vendor/` 的第三方组件、专有运行库、模型或第三方衍生内容，也不替代 SDK 对衍生应用的使用/发布约束。

2026-11-02 重新核对官方 [Expandable Applications](https://www.live2d.com/en/sdk/license/expandable/) 和 [Live2D Open Software License](https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html)：前者明确可添加不定数量模型的应用需要发布前审查和特殊协议；后者对 Publish / Distribute 的定义较广。不能仅凭“没有把 Core 加入 git”就认定源码公开或可执行程序发行已经获准。公开方式与许可适用范围应向 Live2D 核实，本仓库不声明已获得此类授权。

图标由项目作者提供，不使用测试模型的立绘或截图。源码仓库不附带模型选择清单、专有 Core 或旧版运行库。公开前隐私与仓库边界审计见 `PUBLIC_RELEASE_AUDIT.md`。
