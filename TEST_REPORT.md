# Lite2D 验证与交付报告

最终更新：2026-11-02。最终产物：`dist/Lite2D.app`，原生 ARM64、ad-hoc 签名。

## 当前结论与验收范围

- 多实例播放器、所选 Bilibili 22娘 / BiliBili33娘、Cubism Native `.moc3` 支持及逐实例显示器绑定已完成。
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
| M2 | NSEvent.mouseLocation 共享采样、按独立窗口换算、时间低通、官方眨眼/呼吸/物理/姿势/动作/表情；R5 参数更新次序已修正。冻结动画的 33娘左右目标捕获不同、关闭追踪回中 |
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
| F15 | 通过：22 / 33 / Haru 三种同时显示，分别产生实际帧 |
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

每组预热 4 秒、静止目标 300 秒、1Hz 合成移动目标 120 秒；22/33 交替，3/4 含重复资产。360×480 points，30 FPS，追踪与动作开启，无选定模型 Physics 资源。CPU 100% 表示一个核心；MiB 为样本均值。不是连续人工移动鼠标的测试。

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

旧版兼容以首批22/33娘为验收对象，旧版专用物理/姿势/表情、音频和 ViewerEX 自定义控制器未实现；原生 `.moc3` 按官方 Framework 处理可用资源。OpenGL 已弃用；实际运行验证为 macOS 27.2 / M3 Pro，macOS 14 是部署目标而非额外实机验证。显示器 UUID 被系统重新分配时需显式重新绑定。没有公开发布许可或第三方模型再分发授权的声明。
