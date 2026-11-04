# Lite2D 验证与交付报告

## 文件夹与纹理换装导入修复（2026-11-04）

- 文件选择器显式允许 `.folder`，与 JSON/ZIP/LPK/WPK 同时可选，修复类型过滤导致无法选择文件夹的问题。
- 同目录、相同非空角色 `label`、同一核心模型文件路径的入口生成统一衣柜，优先默认入口。已有服装关系不覆盖，不同目录、不同标识、不同核心文件保持独立。
- `python3 scripts/test_model_import.py --costume-folder <本机33目录>` 通过：真实目录识别一个角色、19 套服装；所有服装必要资源验证通过；直接选择某套 JSON 仍保留 19 套，重复导入摘要一致。新增不同标识/不同核心文件不合并的回归通过。
- 默认与替代服装的独立进程 GPU 探针各通过 31 帧、GL error 0；构建、签名和 diff 检查通过。后续验证按用户要求不使用 Computer Use；文件选择器改动未宣称完成 UI 手测。
- 文档同步更新至 `doc/live2d-model-import.md`。原始模型目录没有写入伴随清单；已有角色实例不自动合并，新导入应用此规则。

最终更新：2026-11-02。最终产物：`dist/Lite2D.app`，原生 ARM64、ad-hoc 签名。

## 当前结论与验收范围

- 多实例播放器、两个旧版测试夹具、Cubism Native `.moc3` 支持及逐实例显示器绑定已完成。
- 显示器按 UUID 和屏内 point 位置绑定；缺席时隐藏且零 draw，重连恢复原屏原位置；不再自动搬到主屏。旧配置迁移到 schemaVersion 3。用户拖动和显式菜单可更新绑定，系统自动移动窗口不会改写锚点。
- 最后一轮集成 **171 项**、新进程恢复 **19 项**通过；当前产物再次完成 171 项生命周期检查后，`leaks` 报告 **0 leaks / 0 leaked bytes**，应用正常退出。
- 用户前版模型交互手测无异常。用户明确要求 **Stage Manager、跨 1×/2× DPI 跳过**；**物理插拔之后由用户验证**。Space/全屏和未单列的系统交互作为限制，不冒充实机通过。
- 用户要求停止新增/重复压测：已收取当前全部运行结果，后续交付不以补测为条件，也未再追加压测或优化。

## 环境与依赖

M3 Pro（12 CPU / 18 GPU 核），18 GB；macOS 27.2 (26B123)，arm64；Xcode 27.2 (27B52)，SDK 27.2；CMake 4.4.5、Ninja。三屏均 2×：MateView 1920×1280 points；内屏 1512×982，原点 (1920,-779)；竖屏 1080×1920，原点 (-1080,-625)。

官方 Samples R5：`b8024738f108e6003e4925193e8d5ec04cd18196`；Framework：`c5cc765a885ac95e07fde93f300fab019f8c11f7`。用户授权官方 SDK 许可后下载 Native R5，ZIP SHA-256 为 `7ff3a4bbc19c0a8728965aa522ab77eb11b252916453e68a8a78d3b71188bb12`，Core 自报 6.0.1。GLEW 2.2.0 / GLFW 3.4 使用上游脚本准备。Core / 模型 / 旧版专有运行库未加入 git。

## M0–M5

| 阶段 | 实际完成与证据 |
|---|---|
| M0 | 环境探测；官方 Minimum Demo configure/build Exit 0，arm64；90 帧自动运行 Exit 0；内部 GPU 捕获确认完整模型、帧内容变化、GL error=0。`.local/verification/official/` |
| M1 | AppKit 菜单栏、透明 NSWindow / NSOpenGLView、Objective-C++ 桥接、原生 ModelHost。Hiyori/Haru 内部 RGBA 捕获有纹理与透明像素；无桌面截图。`.local/verification/native-app/`、`xcode-native/` |
| M2 | NSEvent.mouseLocation 共享采样、按独立窗口换算、时间低通、官方眨眼/呼吸/物理/姿势/动作/表情；R5 参数更新次序已修正。冻结动画的 旧版测试 B左右目标捕获不同、关闭追踪回中 |
| M3 | 至少三种模型同时显示、同一路径重复实例、独立 UUID/window/context/bridge/引擎。30 次增删、20 次替换，其他实例继续。新进程恢复全部状态及失效/离线实例 |
| M4 | 菜单独立控制、编辑/穿透、拖动/缩放、撤销移除、绑定显示器与屏内位置、离线隐藏、重连恢复；171 项软件回归。用户手测及未覆盖范围如上 |
| M5 | 0–4 实例各 420 秒 CPU/内存/FPS、GPU timer query、隐藏零 draw、Instruments、压力之后 Leaks、官方同模型/尺寸/FPS 对比；真实 `.app` 与文档已生成。工具不支持的能耗指标明确保留限制 |

## 最后一轮验证命令与产物

- `sh scripts/build.sh`：Exit 0，日志 `.local/sdk/display-binding-release-build.log`。构建脚本执行本机 ad-hoc 签名。
- Xcode 隔离构建 `xcodebuild -project build/xcode-verification/Lite2D.xcodeproj -scheme Lite2D -configuration Release CODE_SIGNING_ALLOWED=NO -jobs 2 build`：Exit 0，`.local/sdk/xcode-binding-build.log` 含 BUILD SUCCEEDED；同一源码清单，Swift 5 / macOS 14 deployment target。
- 单元测试（BUILD.md 完整命令）：Exit 0，覆盖配置修复/迁移/原子保存/损坏备份、实际模型校验、缺必要资源、越界路径、缩放比例极限、显示器身份和屏内坐标。
- `.local/verification/display-binding-release/`：171 项 + 19 项恢复检查；30/60 FPS 为 29.69 / 59.38，在同一固定刷新率显示器测量约 3 秒。
- `.local/verification/post-stress-leaks/run-20261102-013529/`：171 项之后静止扫描；scannerExit=0、zeroLeaks=true、appExit=0。删除视图的弱引用已释放；内存诊断不显示持续单向累积，不把单次零泄漏推论为所有未来模型均无泄漏。

## F01–F24 验收表

“自动”表示应用内接口、实际引擎与 GPU/状态证据，不是系统鼠标事件自动化。

| ID | 结果与范围 |
|---|---|
| F01 | 通过：零实例稳定运行；删除最后实例后菜单仍有添加/退出，能再恢复全部实例 |
| F02 | 通过：原生 Hiyori/Haru 正确纹理、透明 alpha、GL error=0 |
| F03 | 通过：剥离动作/Physics 的原生有效模型仍实际绘制 |
| F04 | 通过：缺 moc / 缺纹理拒绝，仅影响该操作；B/C 保持渲染 |
| F05 | 自动穿透/非焦点追踪通过；用户模型交互总体无异常，Finder 拖动未单列实机结果，作为限制 |
| F06 | 自动编辑选择、用户拖动回调、缩放和独立状态通过；前版用户拖动缩放手测无异常 |
| F07 | 通过（自动）：三屏/负坐标转换、独立目标和屏内绑定；未冒充录制实际系统光标路线 |
| F08 | 跳过：用户明确不使用跨 1×/2× DPI |
| F09 | 软件拓扑通过：断开仅隐藏绑定实例、零 draw，重连同位置；物理拔插由用户后续验证，不阻塞交付 |
| F10 | 通过：隐藏 A 零 draw，B/C 继续，恢复保留状态 |
| F11 | 通过：20 次替换及删除不影响其他 controller；压力后 Leaks 为零 |
| F12 | 通过：新进程恢复 UUID/顺序/名称/位置/比例/追踪/平滑/FPS/暂停/Idle/表情/绑定；错误路径独立标记 |
| F13 | 通过：同屏独立 30/60 FPS，最后约 29.69/59.38 |
| F14 | Stage Manager 跳过；Space/全屏未完整实测，明确限制，不承诺强制全屏置顶 |
| F15 | 通过：旧版 A / 旧版 B / 官方原生示例 三种同时显示，分别产生实际帧 |
| F16 | 通过：重复原生与旧版资产，UUID/context/bridge 与状态独立，删除复制体后源仍正确绘制 |
| F17 | 通过：A 关闭回中、B 跟踪，冻结 B 动画后左右目标仍改变实际模型帧 |
| F18 | 通过：仅目标动画时钟冻结，其余继续 |
| F19 | 通过：逐实例动作/Idle/原生表情设置与持久化，不改 B |
| F20 | 通过：重名区分、UUID 菜单定位、复制、删除和撤销，未使用可变数组索引定位 |
| F21 | 通过：不同逐实例设置、显示器 UUID/屏内坐标与离线显示偏好往返恢复 |
| F22 | 通过：全局隐藏保留偏好，离线绑定不被置前/恢复带到主屏；全部删除仍可控制 |
| F23 | 通过：30 次增删、重复路径、20 次替换；弱引用释放、瞬时 GL error 计数为零，之后 leaks=0 |
| F24 | 通过：1/2/3/4 组合与资源/FPS记录；不是多模型轮播 |

不宣称 24/24 场景均完成了硬件/系统实机验证，跳过与限制按用户最新指示交付。

## 0–4 实例长时基线

每组预热 4 秒、静止目标 300 秒、1Hz 合成移动目标 120 秒；旧版 A/B 交替，3/4 含重复资产。360×480 points，30 FPS，追踪与动作开启，无选定模型 Physics 资源。CPU 100% 表示一个核心；MiB 为样本均值。不是连续人工移动鼠标的测试。

| 实例 | 时长 s | 静止 CPU % | 移动目标 CPU % | 常驻 MiB | 物理占用 MiB | 各实例实际 FPS |
|---:|---:|---:|---:|---:|---:|---|
| 0 | 420.0 | 0.59 | 0.85 | 56.0 | 20.8 | — |
| 1 | 420.0 | 28.21 | 21.77 | 88.6 | 177.2 | 29.92 |
| 2 | 420.0 | 23.25 | 22.95 | 108.7 | 225.5 | 29.91, 29.91 |
| 3 | 420.0 | 36.01 | 38.40 | 138.3 | 263.7 | 29.83, 29.83, 29.83 |
| 4 | 420.0 | 44.62 | 43.73 | 154.7 | 297.7 | 29.84, 29.84, 29.84, 29.84 |

本机其他应用、用户手测和隔离候选构建/验证可能并发，CPU 不严格单调；不能把 1→2 的下降解释为新增实例减少固定 CPU。首个实例 footprint 增量约 156.4 MiB，后续约 48.3 / 38.2 / 34.0 MiB；首个开销包括框架、JIT、窗口、纹理和驱动缓存。首次资源未共享 GPU 纹理，以状态隔离优先。

基线用 SHA 记录的早期稳定构建，`.local/verification/performance/build-receipt.json`；后续绑定版本保留同一旧版渲染路径。没有在中途替换基线二进制，也不把这些数据声称为当前所有模型/环境的保证。

隐藏补充：3 实例运行后隐藏 1 个，剩余两者约 29.83 FPS、隐藏者 0 draw；全部隐藏时三者均 0 draw，诊断采集期间 CPU 约 0.37%。内存保留模型资源以便恢复。记录 `hidden-one/`、`hidden-all/`，各 12 秒，不与 420 秒数据混为同一时长。

## GPU、Instruments 与官方对比

- `GL_EXT_timer_query` 非阻塞区间计时，0–4 场景均无 GL error。各模型绘制区间均值 ms/frame：1 [0.981]，2 [0.732,0.388]，3 [1.221,0.436,0.354]，4 [0.765,0.285,0.373,0.428]。包含预热已收集查询；这是区间耗时，不能当作总 GPU 利用率或瓦特。
- `.local/verification/profiling/launch-20261102-010506/`：Time Profiler / Allocations / Leaks 各独立启动 3 实例，以及 0–4 Activity Monitor，共 8 个记录，xctrace 和目标正常结束，应用自身 summary 存在，GL errorCount=0。Leaks 模板会降低采样帧率（约23 FPS），不用于常态性能结论。
- 热附加 Allocations 的旧方式导致此主机 JSC/注入栈停顿，已弃用该结果；改为启动即记录，避免把工具热附加成功码误当应用完成。一次诊断清理过宽中止并行隐藏场景，已收窄 PID 范围，该被中止结果未计入。
- Power Profiler 实际提示 macOS 不支持（要求 iOS/iPadOS）；Activity Monitor 导出的 schema 也没有 Energy Impact 字段，**未取得或估算 Energy Impact/瓦特**。已有 Idle Wakeups 差分仅为可用代理指标，不冒充能耗：

| 实例 | Activity Monitor CPU % | Physical footprint MiB | Idle Wakeups/s |
|---:|---:|---:|---:|
| 0 | 0.07 | 17.1 | 1.6 |
| 1 | 13.79 | 180.7 | 230.1 |
| 2 | 21.22 | 217.4 | 230.8 |
| 3 | 26.57 | 259.2 | 229.7 |
| 4 | 34.51 | 291.8 | 230.9 |

Activity Monitor 为独立短记录，取启动 4 秒后的样本，不替代长时基线。

官方/AppKit 对比使用相同 Hiyori、360×480 points（720×960 pixels）、30 FPS，约30秒。官方约 30.03 FPS / 7.72% CPU，AppKit约 30.00 FPS / 10.31% CPU。官方不透明 GLFW 与 AppKit 透明合成、动画功能集及后台负载不同，**不据此宣称胜出**。原始记录 `official-comparison/`；临时上游插桩源已恢复，submodule 未改动。

## 交付边界

源码、README、BUILD、TEST_REPORT、第三方说明和生成脚本已交付；`doc/` 保持忽略，不提交个人模型/Core/专有旧运行库或 `.app`。`.app` 只作为本机产物保留于 dist。

旧版兼容以两个旧版测试夹具为验收对象，旧版专用物理/姿势/表情、音频和 ViewerEX 自定义控制器未实现；原生 `.moc3` 按官方 Framework 处理可用资源。OpenGL 已弃用；实际运行验证为 macOS 27.2 / M3 Pro，macOS 14 是部署目标而非额外实机验证。显示器 UUID 被系统重新分配时需显式重新绑定。没有公开发布许可或第三方模型再分发授权的声明。

## 登录启动增量交付（2026-11-02）

- 新增菜单“登录时自动启动”，使用 `SMAppService.mainApp` 登记/撤销主 `.app`；以系统状态决定勾选，等待允许时使用 mixed 状态并提供系统设置入口，失败显示实际错误。异步撤销期间禁用重复操作。不引入额外登录辅助进程或 LaunchAgent。
- 在新目录 `~/Repo/lite2d` 使用 `cmake -S . -B build/login-item -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5` 及 `cmake --build build/login-item --parallel 6`，Exit 0。签名校验通过，实际链接 ServiceManagement.framework。
- 对已签名产物执行一次显式登记/撤销核验，Exit 0：`before=notFound`、`registered=enabled`、`after=notRegistered`，结果 `registrationAndRemovalPassed`。测试登记已撤销，最终由用户通过菜单开启。原始日志 `.local/verification/login-item/`。
- 未进行注销、重启或新增模型压力测试；不把 API 登记成功说成已实测一次真实开机。登录后仍使用既有配置恢复路径和显示器绑定逻辑。
- 工作区出现独立的图标改动，本功能提交只包含 ServiceManagement 依赖及登录项代码/文档，保留并行图标工作。

## 图标与公开源码准备（2026-11-02）

应用作者提供的分层 AppIcon，actool 构建成功，产物包含 Assets.car / AppIcon.icns，签名检查通过。README 加入去除 EXIF/XMP 元数据的静态预览，并移除具体模型名称。测试工具改用通用本地别名、显式运行库路径与显式工坊选择；未重新运行模型压力测试，历史性能数字仍为原先记录。

根仓库历史 Gitleaks 无命中，个人绝对路径/已知设备标识规则未命中；作者邮箱按用户要求保留，未改写历史。自有代码加入 MIT，第三方 SDK 与发布许可单独适用；源码公开不是 Live2D 发行授权证明。具体边界见 docs/PUBLIC_RELEASE_AUDIT.md。

## 本机安装交付（2026-11-02）

新构建目录 `build/deploy` configure/build Exit 0，版本 0.1.1 / build 2；图标 Assets.car 和 AppIcon.icns 均存在，安装前后及 dist 签名校验通过。安装到 `/Applications/Lite2D.app`，仅刷新该应用的 LaunchServices 注册；NSWorkspace 文件级图标服务返回项目自定义图标。旧 dist 和原设置有本地回退备份。

两个用户选定模型已逐文件校验后复制到用户 Application Support 数据目录，配置含两个独立实例，绑定当前主显示器，不引用项目模型目录。已从安装路径正常启动：进程存活、启动日志无模型失败标记，WindowServer 元数据显示两个在线浮动模型窗口。私人模型名、路径、显示器 UUID、导入收据和启动日志仅保留本机，不写入公开文档或 git。没有追加压力测试或真实开机测试。


## 2026-11-02：模型服装切换

- 新增实例菜单「服装」，读取已解包模型的 `change_cos` 引用和 `choices` 名称；22 娘识别为默认 + 18 套替代服装。兼容旧缓存 `.bin` 引用对应 `.json` 的情况，新解包会正确重写引用。
- 切换在现有实例窗口与 GL context 内事务式加载，保留位置、显示器绑定、追踪、暂停、帧率；服装 ID 单独持久化，模型入口路径保留。复制、撤销移除与重启沿用所选服装，更换模型清除旧服装选择。
- Swift 设置/路径测试通过，覆盖 19 套真实资源、旧配置默认值、服装状态往返、未知服装、目录越界、绝对/网络路径和符号链接越界。
- Release 构建通过（`build/outfits`；原 `build/app` 缓存记录了仓库改名前的路径，使用新构建目录），产物 `dist/Lite2D.app`，ad-hoc 签名。
- 完整集成测试 **273 项通过**，新进程恢复 **19 项通过**。19 套均输出互不相同的有效纹理帧、透明背景且 GL error 为 0；默认恢复逐字节一致，未知服装和实际 PNG 解码失败保留原服装与设置，其他实例不受影响。
- 30/60 FPS 实测约 29.85/60.01；原有 30 次添加/移除与 20 次更换回归通过。新进程配置含已选择替代服装的实例，正确恢复。
- 两张代表帧（默认、2016 圣诞节1）已人工式视觉检查。测试记录与逐套 PNG/RGBA 位于 `.local/verification/outfit-integration/`。解包重映射另行验证，19 个命令均指向实际 JSON。
- 支持范围为已解包模型中的 `change_cos` 服装描述引用；没有服装配置的模型不显示服装菜单。未增加通用脚本/ViewerEX 控制器执行器。


## 设置窗口与快捷菜单（2026-11-03）

0.1.1 build 3：Release 构建与 ad-hoc 签名核验通过，已安装到 `/Applications/Lite2D.app` 并打开设置窗口。旧应用和安装前配置备份在忽略目录 `.local/settings-ui/`。安装前确认日常配置未被隔离测试修改。

- 现有配置迁移、序列化、损坏备份和模型路径校验单元测试通过。
- 使用隔离设置实际操作并检查界面及 JSON：重命名、缩放、暂停、点击互动、复制角色、移除当前角色、移除最后一个角色、撤销恢复、全局隐藏原因提示；修复了移除后旧控件读取已移除记录导致的崩溃，并重新验证上述移除流程。
- 内联权重 `0` 写入配置，无效负数显示校验提示；重启恢复缩放、暂停和互动配置。
- Hiyori 原生渲染短探针通过，31 帧，GL error 0，输出有可见像素。
- 安装版窗口实际显示已有角色、原服装与显示器绑定，应用二进制与构建产物 SHA-256 一致。

旧集成测试的菜单断言已跟随新入口调整，本次未重跑完整压力/性能套件。

## 模型包导入验证（2026-11-03）

- `sh scripts/build.sh`：通过，产物 `dist/Lite2D.app`，ad-hoc 签名。未覆盖 `/Applications` 安装版。
- `python3 scripts/test_model_import.py --workshop <本机明确指定的工坊目录>`：通过；11 个真实 Cubism 工坊包导入并验证全部已识别服装（最多 19 套），2 个非 Cubism 包被拒绝。
- 构造的普通 ZIP、多角色/多服装 LPK、嵌套 LPK 的 WPK、JSON、目录、选择结果、重复准备后的摘要复用、取消提交、源文件删除后读取、损坏/越界/链接/冲突条目与缺必要资源等回归通过。测试目录隔离于 `.local/verification/model-import/`。
- 原生普通模型、包内原生角色、真实工坊 Cubism 3+ 与 Cubism 2 导入副本分别通过 `probe_app.py` 新进程 GPU 验证：31 帧、GL error 0、存在可见及透明像素。结果位于 `.local/verification/import-native`、`import-outfit`、`import-real-native`、`import-real-legacy`。
- 实测发现固定 Cubism R5 解析器拒绝部分紧凑数字 JSON，已在原生加载边界统一格式化并加入 SDK 解析有效性检查；修复后包内角色 GPU 验证通过。
- 既有 `SettingsAndValidationTests.swift` 通过。GUI 确认文件选择提示、多角色/服装数量、取消后未创建实例；使用隔离设置，未改日常角色。拖入、真实 EX 界面导出的 WPK 变体、全量 EX 控制器不属于本次已验证结果。


## 四语 i18n 验证（2026-11-03）

- 四语资源：`zh-Hans` / `zh-Hant` / `en` / `ja`，每种 210 个 key；key 集合、非空文案和动态占位符一致。
- `python3 scripts/test_localization.py` 通过：语言匹配、偏好持久化、英语单复数与回退、缓存错误重译、作者/旧名称保留、生成名称序列化兼容。
- `python3 scripts/test_model_import.py` 通过：归档/目录/JSON、角色与服装、去重、源文件删除、异常输入；断言使用稳定错误身份。
- 设置与校验测试通过：旧格式迁移、往返保存、损坏备份、真实模型、路径校验、屏幕绑定。
- Release 构建通过；既有 OpenGL 弃用警告仍存在。
- 应用内集成：350 项通过；新进程恢复：19 项通过。语言切换保留页面/角色选择、模型设置和控制器；未提交输入及文字选区保持不变，切换不会提交改名。
- 四语设置页 16 张截图已生成并检查；另验证已打开的导入选择窗口切换后更新标题、保留选择。
- 本地截图：`.local/verification/integration/localization-*.png`；拼图：`.local/verification/localization/settings-contact-sheet.png`。
- 系统弹窗允许重启后生效；本轮未逐个验证 macOS 系统弹窗的语言缓存行为。


## v1.0.0 发布验证（2026-11-03）

- `App/Info.plist` 更新为 1.0.0 / build 4；`sh scripts/build.sh` Release 构建通过，产物为 ARM64，部署目标 macOS 14+。
- `python3 scripts/test_localization.py`、`python3 scripts/test_model_import.py`、重新编译的 `SettingsAndValidationTests.swift` 均通过；四语 210 key 集合、占位符及错误身份一致。
- 对本次产物运行 `scripts/run_integration.py`，使用隔离设置和偏好：应用内 350 项、新进程恢复 19 项通过，30/60 FPS 短采样约 29.84/59.69。不是新的全面性能或实机显示器验收。
- 原始日志位于忽略目录 `.local/release-1.0.0-*.log`，集成结果位于 `.local/verification/release-1.0.0/`。
- dist 和分发暂存应用均通过 `codesign --verify --deep --strict`。发布应用包检查版本、资源白名单及无模型、个人配置、Finder 元数据；附带 MIT、第三方说明、许可文本和 release log。源码包使用 Git 提交快照生成，不打包本机工作目录。
- 本次发布不覆盖 `/Applications` 安装版，不修改日常角色配置；ad-hoc 签名、未公证及既有实机验收限制不变。


## v1.0.0 动作状态修订验证（2026-11-03，build 5）

- 完整复现 idle → 点击 tap_2 → 自动回到 idle：修复前动作已退出队列，但眼部变形参数停留约 0.132；修复后恢复模型基准值 0，idle 继续运动且不再叠加静止表情。
- 撤回先前仅调整自动眨眼的改动及相应测试，新增 `LegacyMotionLifecycleTests.swift`：覆盖两个 tap 返回三个 idle、连续点击、自选动作组、手动中断时的淡出、无 idle、非零参数基准恢复、部件状态恢复和非动作状态保留。修复前首个残留断言失败，修复后通过。
- 既有 `WeightedMotionTests.swift` 通过：权重区间、零权重排除、缺失动作、极大权重、手动完成恢复循环及点击动作防重入。
- 针对相同动作序列生成修复前后真实 GPU 帧，确认眼部残影消失；探针均为 31 帧、OpenGL error 0，保留透明背景和纹理像素。测试产物仅留在忽略的 `.local/verification/motion-lifecycle-*`。
- 已安装旧版应用仅更新动作脚本并重签名，保留其界面版本与配置；安装版短探针和严格签名校验通过。此次 1.0.0 修订发布包包含当前 1.0 界面与完整修复，未将本地模型、配置或诊断脚本打入附件。
- 本次仅执行针对性回归及渲染检查，未重复完整压力/性能套件；原有实机显示器与公证限制不变。


## v1.0.0 最新修订发布验证（2026-11-04，build 6）

- 基于 `613bb23` 的代码更新发布元数据，版本 1.0.0 / build 6；`sh scripts/build.sh` Release 构建通过，产物为 ARM64 / macOS 14+。
- `python3 scripts/test_model_import.py` 通过：归档、文件夹与 JSON 导入、角色选择、服装归组、去重、源删除和异常输入。
- `python3 scripts/test_localization.py` 通过：211 key × 4，key、占位符与原生错误身份一致；语言切换、持久化、回退及名称兼容回归通过。
- 构建产物、分发暂存副本和 ZIP 解压后的应用均通过 `codesign --verify --deep --strict`；版本与 ZIP 完整性检查通过，应用附件无模型、个人配置、日志或 Finder 元数据。
- 发布日志与应用 README 同步为 build 6；源码附件使用发布提交的 Git 快照生成，应用包与源码包重新计算 SHA-256。日志与暂存产物保留于忽略目录 `.local/release-1.0.0-build6/`。
- 本次未重复完整集成、压力或性能测试，未覆盖 `/Applications` 安装版和日常角色配置。

## Companion v1.1（2026-11-04，build 7）

**交付：** 新增按模型实例绑定 Persona Markdown 的主动陪伴功能，三种工作来源、主动评论/低频闲聊、真实双 Session 角色交流、公共/私有记忆、原生气泡、交流记录、停止与对视。无 TTS、音频、口型或用户聊天输入；角色工具层禁用 Shell、execute、edit、write、external_directory。应用包 1.1.0（build 7），controller 客户端随包提供，Claude 可执行文件不随包分发给用户。

**实际运行验收：**

- `node --test Companion/controller.test.mjs Companion/native.test.mjs`：11 项通过，覆盖记录事务/冲突/作者、Persona 校验、输出隔离、工具宿主即时返回、独立 Session 与 MCP 消息、私聊回送、预算/持续工具调用/重试计费、停止、频率、缓存重置、文本更新检测、重启恢复及上下文消费；权限检查覆盖 shell/execute/edit/write/external_directory 均为 deny。
- 真实 OpenCode 2.2.5 + 本地确定性 OpenAI-compatible 上游：两个角色各自的 Session，A 调工具后 B 独立执行记忆工具并回复，A 以非生成 inbox 接纳；应用重启恢复同一 Session 和私有记忆；不修改用户 Session。
- **真实外部模型**：`homo/gpt-5.6-sol` + 提供的 22/33 人设完成一次双角色消息往来。A 说「三三，晚上好呀！我来看看姐妹频道有没有顺利接通～」，B 说「晚上好，姐姐。姐妹频道已经顺利接通了——这次没被你弄成单向广播，做得不错。」，无错误、两个独立 Session。此次不宣称长期外网可用性；本机默认免费模型额度耗尽、其他几项 provider 返回 502/503 是外部服务状态。
- `LITE2D_CAPTURE_OWN_WINDOW=1 python3 scripts/test_companion.py`：12 项通过，含普通 Markdown、22/33 示例按说话人筛选、四语页面状态、原生窗口、双向视线渲染值、拖动更新、取消/迟到事件释放、气泡非激活面板。截图仅为本测试窗口。
- `python3 scripts/test_localization.py`：276 键 × 4 语言通过，占位符一致。设置单元测试通过（使用 `.local/models` 隔离复制，不含用户模型变化）。
- 构建应用包 7.3 MB，通过 `codesign --verify --deep --strict`，内置 controller 为 1.4 MB。
- 安装后再次从 `/Applications` 内置 bundle 启动隔离 Controller：三种来源状态均为 available（本项目 OpenCode 0、Claude 2、Codex 12 个近期会话），正常关闭且无遗留观察进程。运行中的日常应用通过 ready/status 事件确认 Companion 已成功加载；用户项目授权列表保持空。

**已知边界：** OpenCode MCP 在 “connected” 后有一定注册时延；已在连接后等待工具注册完成再启动。共享小时预算基于请求数，无法覆盖 OpenCode 内部 provider 精确计费。Claude 历史读取不是文件尾部增量，跨进程更新时延与读取成本按实际 SDK 表现。工作来源默认不授权目录；观察内容可能发送给角色所用模型服务。对视脸部锚点仍是按窗口约 50%/70% 的默认估计，不同模型可能有偏差。

安装验证修正了两项问题：Companion 设置解码支持缺省字段，避免旧配置整份失效；移除 jsonc-parser 的 UMD 打包路径，provider 配置通过本机 OpenCode 接口读取，已重验实际安装版 Controller 启动。

**安装：** `/Applications/Lite2D.app` 已同步为 1.1.0（build 7），严格签名校验与运行中进程核对通过。已按现有模型实例 UUID 绑定用户提供的 22/33 Persona 与各 152 条可选原创风格示例；启用 30 分钟闲聊间隔，使用已实际验证的 `homo/gpt-5.6-sol`。三种工作来源默认不授权目录，原有播放器设置未修改。安装版已记录 Controller 的 ready/status 事件。

## Companion v1.1.1（2026-11-04，build 8）

- 观察范围改为来源级开关，开启后跨项目/工作树分页枚举本机全部可读取对话，包括接口可枚举的归档。移除项目选择，旧项目设置迁移为来源开关；排除新旧角色 Session（包含重置/移除的历史），避免将自己的台词当作工作进展。
- 每轮限定近期/变化尾部读取，全部历史元数据分页列出，不把大量旧对话全部读入角色。初次建立基线不触发台词；关闭来源撤回缓存与工具访问。
- 每个模型的陪伴页增加「触发一次对话」。手动触发只选择对应模型实例，跳过定时/冷却等待，仍遵守陪伴开关、角色启用、可见性、勿扰、忙碌和共享预算。不增加聊天输入框。
- `node --test Companion/controller.test.mjs Companion/native.test.mjs`：14 项通过，新增目标角色、冷却跳过、勿扰/隐藏/重复点击/预算拒绝、来源授权撤回、跨项目与归档分页、角色 Session 过滤验证。
- 原生专项验收 19 项通过，包含旧项目设置迁移、每角色测试按钮的启用条件及拒绝后忙碌状态释放。四语 280 键校验通过，新增页面维持原生分组表单。
- 全局接口实际枚举到 OpenCode 344、Codex 344、Claude 17 个会话，覆盖 58/50/6 个项目标识；数目为该次探测统计，随后排除本应用角色 Session 后数量可能下降。三个来源初始 poll 的变化数均为 0，各只缓存 6 个近期尾部。
- 使用 `homo/gpt-5.6-sol` 和提供的两份 Persona，分别执行所选角色的 trigger 命令，22/33 均真实生成简短问候，无 skip 或错误。测试不依赖 computer use。
- 已更新并启动 `/Applications/Lite2D.app` 1.1.1（build 8），保留两角色 Persona/记忆与原有布局，按本次指令开启三种来源的全部会话观察。安装后实时状态为 available：OpenCode 302、Codex 344、Claude 17；OpenCode 数量排除了保留在原存储中的本应用角色测试/历史 Session。安装文件哈希与构建一致，严格签名校验通过。
