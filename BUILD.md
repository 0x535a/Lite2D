# 构建记录

## 本机环境

2026-11-01：Apple M3 Pro（12 核 CPU / 18 核 GPU），18 GB；macOS 27.2 (26B123)，arm64；Xcode 27.2 (27B52)，SDK 27.2；CMake 4.4.5，Ninja。三显示器均为 2× backing scale，存在负屏幕坐标。

`xcrun swift` 实际编译运行 AppKit / OpenGL 导入及 NSOpenGLView 类访问成功，Exit 0。OpenGL 的弃用警告属于首版已接受技术债；该检查不证明模型渲染成功。

## 固定依赖

- CubismNativeSamples：官方 `5-r.5`，`b8024738f108e6003e4925193e8d5ec04cd18196`。
- CubismNativeFramework：Samples 引用的 `c5cc765a885ac95e07fde93f300fab019f8c11f7`。
- GLEW 2.2.0 / GLFW 3.4：使用官方 Sample 提供的下载脚本。
- Cubism Core：须从官方 SDK 获取，不能从未知镜像获取或提交二进制。

```sh
git submodule update --init --recursive
sh vendor/CubismNativeSamples/Samples/OpenGL/thirdParty/scripts/setup_glew_glfw
```

官方 [Native 下载页](https://www.live2d.com/en/sdk/download/native/) 的 `download.js` 当前列出 R5，发布日期 2026-04-02。页面明确要求同意许可，且下载即视为同意；用户已于本轮明确同意并授权下载用于本机开发。

获得授权后可使用 `scripts/install_core.py --accept-sdk-license` 从该页面实际引用的官方 URL 下载，或传入已下载的 SDK ZIP。脚本仅安装 Core，不覆盖固定 Samples / Framework。

## 官方 Minimum Demo

先完成官方 Demo 的构建与可见模型验证，再集成 AppKit。官方 NOTICE 指出 GLEW 2.2.0 与 CMake 4 的兼容问题，因此使用 CMake 的 `CMAKE_POLICY_VERSION_MINIMUM=3.5` 兼容参数，保留上游源码。

```sh
cmake -S vendor/CubismNativeSamples/Samples/OpenGL/Demo/proj.mac.cmake \
  -B build/official-minimum -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCSM_MINIMUM_DEMO=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/official-minimum --parallel 6
```

上述命令已执行，configure/build 均 Exit 0。可使用 `python3 scripts/probe_official_demo.py` 进行 90 帧的程序内 GPU readback 验证；运行正常退出，模型可见且帧内容变化。该脚本临时插入采样，构建后恢复上游源文件，不操作桌面输入或捕获桌面。

`python3 scripts/prepare_test_models.py` 将选定工坊模型读取到忽略的 `.local/models/`，保留来源收据，不改动 Steam 资源。`xcrun swift Tests/LegacyCPUProbe.swift` 验证已有 Cubism 2 JS 运行库在进程内 JavaScriptCore 中加载模型，不使用 Pixi 或 WebView。GPU 适配仍待实现。
## AppKit 原型构建

```sh
sh scripts/build.sh
python3 scripts/probe_app.py vendor/CubismNativeSamples/Samples/Resources/Hiyori/Hiyori.model3.json --name native-app
```

构建和程序内 GPU 验证均 Exit 0。产物 `dist/Lite2D.app` 为 ARM64，使用 ad-hoc 签名。当前仅为基础渲染里程碑，功能进度见 TEST_REPORT。CMake 生成原生项目；GL 资源隔离补丁在构建目录生成，固定上游源码保持原样。
