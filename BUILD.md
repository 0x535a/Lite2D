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

`python3 scripts/prepare_test_models.py` 将选定工坊模型读取到忽略的 `.local/models/`，保留来源收据，不改动 Steam 资源。`xcrun swift Tests/LegacyCPUProbe.swift` 验证已有 Cubism 2 JS 运行库在进程内 JavaScriptCore 中加载模型，不使用 Pixi 或 WebView。GPU 适配已完成，实际结果见 TEST_REPORT。
## AppKit 构建

```sh
sh scripts/build.sh
python3 scripts/probe_app.py vendor/CubismNativeSamples/Samples/Resources/Hiyori/Hiyori.model3.json --name native-app
```

构建和程序内 GPU 验证均 Exit 0。产物 `dist/Lite2D.app` 为 ARM64，使用 ad-hoc 签名。多实例和显示器绑定已完成，验收范围见 TEST_REPORT。CMake 生成原生项目；GL 资源隔离补丁在构建目录生成，固定上游源码保持原样。

## 旧版模型兼容依赖

```sh
python3 scripts/install_legacy_runtime.py "/path/to/authorized/live2d.min.js"
python3 scripts/prepare_test_models.py --item "<ITEM_ID_A>:legacy-a" --item "<ITEM_ID_B>:legacy-b"
sh scripts/build.sh
python3 scripts/probe_app.py .local/models/legacy-a/model.json --name legacy-22
python3 scripts/probe_app.py .local/models/legacy-b/model.json --name legacy-33
```

运行库安装器要求显式传入你有权使用的旧版运行库路径，不依赖其他本地项目。没有从第三方下载 Core，不提交运行库或模型。宿主适配脚本 `Resources/legacy-host.js` 为本项目代码。兼容路径使用进程内 JavaScriptCore 加原生 OpenGL，既不启动浏览器，也不启动额外常驻服务；实际性能与工具限制见 TEST_REPORT。

## 多实例验证

```sh
python3 scripts/run_integration.py
xcrun swiftc -parse-as-library App/Localization.swift App/DisplayLayout.swift App/ModelInstanceSettings.swift App/SettingsStore.swift App/ModelFileValidator.swift App/ModelOutfit.swift App/ModelMotion.swift Tests/SettingsAndValidationTests.swift -o .local/verification/unit/settings-tests
.local/verification/unit/settings-tests
xcrun swiftc -parse-as-library Tests/WeightedMotionTests.swift -o .local/verification/unit/weighted-motion-tests
.local/verification/unit/weighted-motion-tests
xcrun swiftc -parse-as-library Tests/LegacyMotionLifecycleTests.swift -o .local/verification/unit/legacy-motion-lifecycle-tests
.local/verification/unit/legacy-motion-lifecycle-tests
```

集成测试通过独立 `LITE2D_SETTINGS_PATH` 隔离设置；运行旧版测试夹具 A/B、官方原生示例和重复模型，进行 30 增删、20 替换与新进程恢复。内部帧捕获和 JSON 结果保存在 `.local/verification/integration/`，程序正常退出；不依赖 Computer Use。`scripts/probe_app.py` 可继续单模型诊断。

## 资源测量

```sh
python3 scripts/benchmark.py
python3 scripts/summarize_benchmark.py
```

默认顺序测量 0/1/2/3/4 实例，每组预热 4 秒、静止目标 300 秒、移动目标 120 秒，约 35 分钟。旧版测试夹具 A/B 交替加载，3/4 实例包含重复模型。各实例 360×480 points、30 FPS、穿透、追踪/动画开启。模型纹理和运行库全部本机读取，不启动额外运行时服务。每秒记录进程 CPU（100% 代表一个核心）、resident、physical footprint、逐实例 draw 和 GL error。

为遵守不使用 Computer Use 的要求，移动阶段使用应用内共享目标轨迹（每秒变化），不移动系统鼠标；这不是人工连续移动鼠标的测试。结果必须按此条件解释。测试配置和输出均隔离于 `.local/verification/performance/`，未完成场景在汇总中明确标记。

## 生成 Xcode 工程

```sh
sh scripts/generate_xcode.sh
xcodebuild -project build/xcode/Lite2D.xcodeproj -scheme Lite2D -configuration Release CODE_SIGNING_ALLOWED=NO build
```

已在 `build/xcode-verification` 实际验证 Xcode 构建，Exit 0。Xcode 的产物默认在 `dist/Release/Lite2D.app`；Ninja 的产物为 `dist/Lite2D.app`。可用 `-DLITE2D_OUTPUT_ROOT=/absolute/output` 在独立 CMake build 目录隔离候选产物，避免覆盖运行中的基线。显式使用 Swift 5 语言模式，macOS 14 deployment target；本机用 ad-hoc 签名，无需开发证书。

运行独立单元测试前先执行 `python3 scripts/create_test_fixtures.py`，以准备本地原生无可选资源、缺必要资源的夹具；不提交模型数据。集成脚本会自动准备这些夹具。

## 最终构建与绑定迁移

当前产物 `dist/Lite2D.app` 已构建、ad-hoc 签名并运行验证。配置为 schemaVersion 3，包含每实例 `displayUUID`、`boundDisplayName`、`displayPosition`（屏内 point 坐标）；旧配置只迁移一次，离线显示器不会回落到主屏。显示器绑定回归采用应用内拓扑替换，不操作系统显示设置。

最终单元测试命令：

```sh
python3 scripts/create_test_fixtures.py
mkdir -p .local/verification/unit
xcrun swiftc -parse-as-library App/Localization.swift App/DisplayLayout.swift App/ModelInstanceSettings.swift App/SettingsStore.swift App/ModelFileValidator.swift App/ModelOutfit.swift App/ModelMotion.swift Tests/SettingsAndValidationTests.swift -o .local/verification/unit/settings-tests
.local/verification/unit/settings-tests
xcrun swiftc -parse-as-library Tests/WeightedMotionTests.swift -o .local/verification/unit/weighted-motion-tests
.local/verification/unit/weighted-motion-tests
xcrun swiftc -parse-as-library Tests/LegacyMotionLifecycleTests.swift -o .local/verification/unit/legacy-motion-lifecycle-tests
.local/verification/unit/legacy-motion-lifecycle-tests
```

已收取的验证、长时基线、GPU 区间计时、Instruments 及压力之后的 Leaks 结果见 TEST_REPORT。用户已要求停止新增/重复压测，交付不再依赖补测。Stage Manager / 跨 DPI 跳过，物理插拔由用户后续验证。

原始诊断与测量文件仅保留于忽略的 `.local/verification/`，可能含本机路径和 Instruments 环境元数据，不随源码或 `.app` 公开发布。

## 登录项支持（2026-11-02）

通过系统 ServiceManagement.framework 的 `SMAppService.mainApp` 管理主应用登录项，要求已签名的 `.app`；现有 ad-hoc 构建在本机登记/撤销验证成功。菜单开关不会在普通启动或恢复模型时自动改动登录设置，也不把系统状态复制成 JSON 布尔值。

项目已移动到 `~/Repo/lite2d`，本轮在新目录下以 `build/login-item` 重新配置，避免复用旧目录的 CMake 绝对路径缓存；产物仍为 `dist/Lite2D.app`。诊断参数 `--login-item-status` 只读系统状态；`--check-login-item-registration` 是显式登记/撤销核验，已有登记时保留原设置。无需重复运行或进行注销/重启压测。

## 应用图标与公开源码

`Resources/AppIcon.icon` 是分层图标源。构建需要支持 Icon Composer `.icon` 的 Xcode 26+（当前验证为 Xcode 27.2）；运行部署目标仍为 macOS 14+。CMake 在签名前调用 actool，生成 `Assets.car` 与旧系统使用的 `AppIcon.icns`；Info.plist 同时配置图标名称与文件。README 使用 `docs/assets/app-icon.png` 静态预览，已去除 EXIF/XMP 文本元数据。

测试脚本使用通用本地夹具 `legacy-a` / `legacy-b`，不内置个人模型选择。准备工坊测试资源时显式提供 `--item ID:ALIAS`，只处理你有权使用的本地资源；也可自行准备标准模型目录。安装旧版运行库须提供授权文件路径。模型收据、真实路径、测试日志和所有生成物保留在忽略目录中。

自有代码采用 MIT；Live2D 相关组件、衍生部分及发行要求单独适用。不要把 `.local`、`doc`、SDK Core、模型或本机 `.app` 当作源码公开包附带上传，详见 `docs/PUBLIC_RELEASE_AUDIT.md`。

## 本机安装

本机安装产物位于 `/Applications/Lite2D.app`，版本 0.1.1（build 3）；`dist/Lite2D.app` 同步更新。此版本使用新的构建目录重新编译、在签名前生成图标资源，并对安装路径单独刷新 LaunchServices 注册，未清除全局图标缓存。

模型应存放在稳定的数据目录，例如 `~/Library/Application Support/Lite2D/Models/`，不依赖项目目录。部署时备份现有设置，按现有 schema 追加模型实例并绑定显示器，不把私人资产或配置加入 git。登录启动沿用系统设置，不因安装而自动开启。

## Companion 构建依赖（2026-11-04）

Companion Controller 使用 Node.js 24+ 和 `Companion/package-lock.json`。`sh scripts/build.sh` 发现 `Companion/node_modules/esbuild` 缺失时会先执行 `npm ci --prefix Companion --ignore-scripts`，然后用 esbuild 生成 `Contents/Resources/Companion/main.mjs`，不会在用户机器上安装依赖。Python 脚本 `scripts/test_companion.py` 使用本应用内置 controller 和 CLI 探测；不驱动桌面输入。

### v1.2.0 更新（2026-11-05）

生产 Controller 现为 `App/NativeCompanion*.swift`，链接系统 SQLite3、Network 和 CoreServices。构建阶段只将官方 Claude 历史 SDK 打包为 `claude-helper.mjs`，并从集中编辑的 `prompt.mjs` 生成 Swift 可读的 `prompt.json`；不会安装常驻 Node Controller 或 Claude 可执行文件。运行时只在需要 Claude SDK 读取时启动 Node，默认闲置 60 秒退出。旧 JavaScript Controller 保留作回归/资源基线，不进入应用包。

执行 `python3 scripts/test_native_companion.py` 验证原生 Controller、SDK 助手、真实 OpenCode 与原生 MCP；`scripts/profile_companion_runtime.py` 和 `scripts/profile_companion_app.py` 提供有界资源对比，详见 `docs/COMPANION_RUNTIME.md`。


## 设置窗口与快捷菜单（2026-11-03）

本机预览构建为 0.1.1（build 3），新增 SwiftUI 分组设置窗口，保留逐角色快捷菜单与换装。`--show-settings` 可在启动后直接打开设置；再次打开应用会显示现有设置窗口。配置 schema 不变，沿用现有角色及显示偏好。构建脚本改用当前仓库路径的 `build/app-lite2d`，避开迁移前 `build/app` 中的旧绝对路径缓存。

## 原生对话框整理（2026-11-03）

导入流程里的“选择要添加 / 替换的角色”和“正在导入”原先用 `NSAlert` 与手摆坐标的 `NSPanel` 拼成，现统一为 SwiftUI 分组表单（`App/ImportDialogs.swift`）：多角色为复选列表并带全选与已选计数，替换为单选组，打包警告在“注意”分组中列出，底部固定取消与确认按钮；进度窗口使用系统环形进度。设置窗口修正了打开时角色名输入框自动全选、窗口未激活时名称显示为空的问题，大小与动作权重改用步进器，模型文件与角色管理按“标签 + 控件”排列。原先独立的动作权重窗口已无入口（权重在设置窗口中编辑），已移除。`--self-test` 会驱动这些窗口并保存 `character-picker-multi.png`、`character-picker-single.png`、`import-progress.png` 到集成输出目录。

## 模型包导入（2026-11-03）

新增 LPK/WPK/ZIP、目录和 JSON 的统一导入与模型库保存。ZIP 桥接链接 macOS 系统 `libarchive`，不依赖 Homebrew 动态库或 Python 运行时；新 SDK 缺少 libarchive 头文件时，桥接文件声明所需的稳定公开 C ABI。Swift 侧使用系统 CryptoKit。构建仍执行 `sh scripts/build.sh`，产物为 `dist/Lite2D.app`。

运行 `python3 scripts/test_model_import.py` 验证导入。可选 `--workshop /path/to/616720` 只读验证显式指定的本机工坊资源。测试会重建 `.local/verification/model-import/`；日常配置和原资源不变。GUI 验证可分别设置 `LITE2D_SETTINGS_PATH` 和 `LITE2D_MODEL_LIBRARY_PATH` 隔离设置、模型库。


## 四语本地化验证

```sh
python3 scripts/test_localization.py
```

资源、即时切换和模型名称兼容规则见 [docs/I18N.md](docs/I18N.md)。应用内集成测试同时输出四语设置页截图。


## v1.0.0 发布构建（2026-11-03）

`sh scripts/build.sh` 生成 `dist/Lite2D.app`，版本 1.0.0（build 6），ARM64 / macOS 14+，ad-hoc 签名。分发附件为 `Lite2D-1.0.0-macOS-arm64.zip`、`Lite2D-1.0.0-source.zip` 和 `SHA256SUMS.txt`；源码包是 Git 提交快照，构建前仍需准备 submodule 和专有运行库。发布记录见 `docs/releases/v1.0.0.md`，本次没有更新 `/Applications` 中的安装版。


## v1.0.0 动作状态修订（2026-11-03）

保持版本号 1.0.0，构建号更新为 5。旧版动作退出队列后恢复不再被任何活动动作控制的参数与部件状态，避免点击动作的眼部变形残留在 idle 上；撤回先前的眨眼逻辑调整。对应回归为 `Tests/LegacyMotionLifecycleTests.swift`，权重测试继续保留。修订包沿用原有发布附件名称并更新 SHA-256；源码附件从本次提交生成，两边 v1.0.0 标签同步到本次提交。未重复完整压力/性能测试。


## v1.0.0 导入与动作开关修订（2026-11-04）

基于 `613bb23` 更新发布元数据，版本保持 1.0.0，构建号更新为 6。包含文件夹选择恢复、带角色标签的共享模型纹理服装归组，以及设置页正向动作开关与四语文案。重新构建应用，沿用附件名称并更新校验值、发布日志及两边 v1.0.0 标签；源码附件为本次发布提交快照。
