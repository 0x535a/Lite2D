# 第三方依赖与许可

- [Cubism Native Samples](https://github.com/Live2D/CubismNativeSamples) 与 [Framework](https://github.com/Live2D/CubismNativeFramework)：使用官方 submodule，版权归 Live2D Inc.，适用上游 LICENSE / NOTICE 及 Live2D Open Software License。不要把它们描述为 MIT。
- Cubism Core：Live2D Proprietary Software License，官方 [Native SDK 下载](https://www.live2d.com/en/sdk/download/native/)。专有二进制不提交到 Git；发行附件是否可附带须单独确认，不能从本项目 MIT 推导。
- GLEW / GLFW / stb_image：官方 Sample 的第三方依赖，各自许可见其源码；下载/生成目录不提交。
- 首批个人测试模型来自已安装 Live2DViewerEX 的工坊资源，作者及来源信息保留在原始 config.json。资源仅本机测试，不提交或再分发；订阅或解包不赋予再发布权。
- 旧版 Cubism 2 使用本机已有 `Live2D 2.1.00_1` JavaScript 运行库，以独立 JavaScriptCore VM 执行，原生 OpenGL 提供绘制 API。该运行库为 Live2D 专有内容，保持本地、记录来源及 SHA，不随源码再分发。旧版 SDK 的许可和现代 Core 的许可需分别考虑；不宣称 Cubism 5 Core 可以直接兼容旧模型。

个人开发许可不等于发行许可。该应用可导入不定数量模型，可能属于 [Expandable Application](https://www.live2d.com/en/sdk/license/expandable/)，公开发行前应向 Live2D 核实并完成相应协议。源码、Core、模型各自的许可不能互相替代。

宿主复用 Framework 的公共 API，NativeHost 的资源加载和更新流程参照官方 Minimum Demo；依赖中的版权与许可仍适用。`scripts/isolate_gl_contexts.py` 仅生成 GL 资源单例按 context 隔离的构建副本，不改变模型解码、物理或蒙版算法。

## 自有代码与公开边界

项目原创代码与原创图标资源按根目录 `LICENSE` 的 MIT 条款提供。该许可不覆盖 `vendor/` 的第三方组件、专有运行库、模型或第三方衍生内容，也不替代 SDK 对衍生应用的使用/发布约束。

2026-11-02 重新核对官方 [Expandable Applications](https://www.live2d.com/en/sdk/license/expandable/) 和 [Live2D Open Software License](https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html)：前者明确可添加不定数量模型的应用需要发布前审查和特殊协议；后者对 Publish / Distribute 的定义较广。不能仅凭“没有把 Core 加入 git”就认定源码公开或可执行程序发行已经获准。公开方式与许可适用范围应向 Live2D 核实，本仓库不声明已获得此类授权。

图标由项目作者提供，不使用测试模型的立绘或截图。源码仓库不附带模型选择清单、专有 Core 或旧版运行库。

## v0.1.1 发布记录

维护者已明确确认此次 `.app` 中专有 Core 与旧版运行库的发行授权，并要求发布不含模型、配置的应用包。v0.1.1 附带 MIT、第三方说明及相关上游许可文本；Git 源码仍不提交专有库。这是维护者的授权确认记录，不是本项目签发的 Live2D 官方许可证明，最终适用协议仍由维护者负责核实。

## Companion 客户端组件（v1.1）

本机应用包新增 JavaScript 客户端组件 `@opencode/client@2.2.5`（MIT）及 `@anthropic-ai/claude-agent-sdk@0.3.318` 的历史读取函数（Anthropic 许可和使用条款）。实际进入单文件 bundle 的包与许可记录在应用内 `Contents/Resources/Companion/THIRD_PARTY_NOTICES.md`。构建工具 esbuild 仅用于构建，不作为运行服务；Claude CLI/SDK 平台可执行文件、用户模型与 Persona 包均不随本次应用客户端打包。第三方客户端许可不因本项目 MIT 而改变，公开分发前应按所选版本条款核对。
