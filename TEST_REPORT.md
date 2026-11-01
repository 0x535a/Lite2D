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

## M1 AppKit 宿主（基础渲染已验证）

- `sh scripts/build.sh` Exit 0；`dist/Lite2D.app/Contents/MacOS/Lite2D` 为 arm64；`codesign --verify --strict dist/Lite2D.app` Exit 0（本机 ad-hoc 签名）。
- `python3 scripts/probe_app.py vendor/CubismNativeSamples/Samples/Resources/Hiyori/Hiyori.model3.json --name native-app` Exit 0。30 帧后自行正常退出，720×1080 backing buffer，GL error=0。
- 内部 RGBA 捕获有 135176 个可见 alpha 像素、642424 个全透明像素，各 RGB 通道非零；检查 PNG 确认角色纹理。捕获来自本程序 framebuffer，不使用 Computer Use 或桌面截图。
- 修复 SDK Option 回调对象生命周期（必须进程级存活）、R5 强制 mipmap 采样导致黑色模型、Scale 覆盖投影比例的问题。
- R5 的 shader / offscreen pool 原为全局单例。构建时生成按 CGLContext 区分的版本，不修改 submodule；下一阶段需多上下文增删实测。
- 单实例原型可通过命令行传模型路径，显示透明穿透窗口并提供退出菜单。尚未完成输入校验、添加模型菜单、鼠标追踪、多实例和恢复，不能认定完整 M1 错误输入验收或 M2–M5 通过。

## Cubism 2 兼容路径（22/33娘已实际绘制）

- 复用本机已有 `Live2D 2.1.00_1` 运行库，在每实例独立 JavaScriptCore VM 执行；绘制调用映射到该实例的原生 OpenGL context。未引入 Pixi、DOM、WebView、浏览器或其他进程；不自行实现 `.moc` 解码/蒙版。
- `python3 scripts/probe_app.py .local/models/bilibili-22/model.json --name legacy-22` 和 33 对应命令均 Exit 0，30 帧正常退出，GL error=0。内部帧图确认角色完整纹理和透明背景。
- 22娘可见 alpha 129442 像素，33娘 126084 像素（720×1080）。修复 GLEW 初始化、TypedArray backing-store 字节偏移、Cubism 2 所需 texture flipY 和预乘 alpha。未将首次贴图错位但 GL error=0 的结果计为通过。
- 专有旧运行库只存在忽略目录；来源收据位于 `Resources/LegacyRuntime/source-receipt.json`。仅测试选定模型，未声称任意 Cubism 2 表情/物理均已支持。

## M2–M4 / 多实例集成（自动化路径已验证）

2026-11-02：`python3 scripts/run_integration.py` Exit 0。实际程序中 127 项检查 + 新进程恢复 17 项检查通过。细项与帧图位于 `.local/verification/integration/`，通过应用内接口测试，无 Computer Use、事件注入或桌面截图。

- 22 / 33 / Haru 三实例同时显示；另测试重复 Haru 和重复 22，共四个独立窗口/context/bridge。删除重复原生模型后源模型仍正确绘制，验证按 context 的 shader/FBO 隔离。
- 逐实例显示、暂停、追踪、编辑、缩放、置前、动作/Idle 与原生表情操作；菜单列出四个实例；关闭 A 追踪平滑归中，冻结动画的 B 可随左右目标改变几何。目标通过共享鼠标采样器的测试输入提供，不移动系统光标。
- 隐藏一个、全部隐藏、模拟睡眠路径时相应实例 draw 计数保持不变，其他可见实例继续绘制；全局隐藏不覆盖逐实例可见偏好。
- 三个实际 NSScreen 坐标变换往返，包括负坐标；窗口可恢复到可见区域。实际跨不同 DPI（本机均 2×）、物理拔屏、Space/全屏/Stage Manager 和手动拖动滚轮交互尚未实测。
- 30 次增删，每个临时实例先实际渲染，弱引用检查所有已删除 view 均释放；20 次模型替换，不影响 B 的 controller。失败添加/替换不损坏已有实例。
- 新进程恢复四实例及 UUID/顺序/名称/frame/scale/追踪/平滑/FPS/暂停/Idle/表情；额外插入失效模型后，仅其描述符记录错误，其余恢复。隐藏实例零 draw。损坏配置、重复 UUID 和越界路径单独测试通过。
- 帧率复测：A30=29.968，B60=59.937 FPS，测量 2.102 秒；CADisplayLink callback / scheduled / draw 计数一致。早期 38 次重绘和后续跳帧结果不计通过，修复 AppKit 额外绘制入口及 display clock 节流后通过。
- Time Profiler 10 秒采集输出已保存；5592 个样本中 3342 栈包含 JSValue，2085 包含 ObjC callback，1030 包含旧 glCall。旧运行库 GL 调用改成有序批处理以减少桥接成本，保持官方解码/蒙版实现；批处理后图像与生命周期测试均通过。

## M5 性能与交付（进行中）

已完成 30 次增删和 20 次替换的功能/释放验证；0–4 实例资源成本、5 分钟静止/2 分钟移动目标、Allocations/Leaks、GPU/能耗与官方等条件比较尚未完成，不能宣称性能目标已达成。

F01–F24 最终验收表仍待逐项审计；未实测的桌面行为不会由程序内状态测试代替。`dist/Lite2D.app` 是当前可运行构建，仍需后续验收和文档完善。

### 2026-11-02 性能测试启动

- 资源采集器使用 getrusage（进程 CPU）与 task_info/TASK_VM_INFO（resident、physical footprint），每秒记录逐实例 draw 和 GL error。
- 短程 smoke：0/3 实例各 5 秒静止 + 3 秒移动目标，均正常退出；0 实例平均 CPU 0.18%，3 实例 42.80%。时长不足，不作为正式性能结论。
- 正式 0–4 场景已启动，每场景预热 4 秒后 300 秒静止 + 120 秒应用内移动目标，总计约 35 分钟。运行进度以 `.local/verification/performance/active-process.json` 对应 PID 和实际进程状态核实，不能单独把该文件视为运行证明。
- 本机 Bilibili 22娘：moc 188029 字节，4 张纹理共 626626 字节；33娘：moc 116879 字节，4 张纹理共 647856 字节。磁盘字节不等于解码/GPU 内存。

### 实机验收安排

用户已选择自行验证桌面交互，结果尚待回复。已启动使用独立 bundle ID / settings 的手测副本，模型名称以“手测”开头；步骤见 `docs/MANUAL_ACCEPTANCE.md`。该副本不是播放器的后台依赖，可从自己的菜单退出。性能测量进程使用另一份隔离配置；手测副本与其他用户应用的并发系统负载需在分析 GPU/调度波动时考虑，不把本机数据当受控实验室结论。

已准备 `scripts/compare_official.py`（同一 Hiyori、360×480 points、30 FPS 的官方/AppKit 比较）、`scripts/generate_xcode.sh` 和本地缺失资源 fixture 生成器；它们的运行验证安排在正式长时基线之后，当前不标记为已通过。

### 2026-11-02 候选回归与构建复核

- 候选构建输出隔离到 `.local/candidate/`，未替换正在进行 0–4 长时测试的 `dist` 基线二进制；基线 SHA 已记录于 `.local/verification/performance/build-receipt.json`。
- 新回归 `LITE2D_APP_PATH=.../.local/candidate/Lite2D.app/Contents/MacOS/Lite2D LITE2D_INTEGRATION_OUTPUT=.../.local/verification/candidate-integration python3 scripts/run_integration.py` Exit 0：147 项集成检查 + 17 项新进程恢复检查通过；30/60 FPS 分别 29.879 / 59.758。
- 增加原生无动作/无 Physics 的有效模型实测、缺 moc/纹理失败隔离、移除最后一个实例后菜单存活、全量清理再恢复所有 renderer。修正原生 R5 表情/视线更新顺序，并设置 Motion 的 EyeBlink Effect IDs。
- 坐标与 zOrder 极端值限幅的单独设置/校验测试 Exit 0；避免损坏配置用巨大窗口坐标或 Int.max 排序进入 AppKit。
- 压力采样（4 个描述符，MiB）：

| 阶段 | Resident | Physical footprint |
|---|---:|---:|
| before-add-remove | 265.2 | 478.2 |
| after-10-add-remove | 271.5 | 487.2 |
| after-20-add-remove | 253.3 | 453.0 |
| after-30-add-remove-settled | 253.6 | 450.8 |
| after-10-replace | 262.3 | 456.3 |
| after-20-replace-settled | 262.1 | 451.0 |
| after-zero-and-restore-settled | 217.6 | 425.8 |

这些是同进程生命周期诊断采样，含捕获、JIT 和资源缓存，不能代替 Leaks 工具。30 次增删和 20 次替换没有表现为持续单向增长，全部 renderer 清理再恢复后进一步回落。

- GPU 可选诊断通过 `GL_EXT_timer_query` 非阻塞读取。0–4 每场景 4 秒预热、5 秒静止、5 秒 1Hz 移动目标，GL error 均为 0、实际约 30 FPS。各实例 GPU 绘制区间均值（含预热已收集的查询，ms/frame）：1 实例 [0.981]，2 [0.732,0.388]，3 [1.221,0.436,0.354]，4 [0.765,0.285,0.373,0.428]。这是绘制区间耗时，不是整 GPU 利用率或能耗；系统其他进程和上下文调度会影响值。原始记录 `.local/verification/gpu-matrix/`。
- Xcode 生成脚本 Exit 0。以隔离输出执行 `xcodebuild -project build/xcode-verification/Lite2D.xcodeproj -scheme Lite2D -configuration Release CODE_SIGNING_ALLOWED=NO -jobs 2 build` Exit 0，日志含 BUILD SUCCEEDED。修复 CMake Xcode 默认 Swift 4，显式固定 Swift 5。Ninja 与 Xcode 使用同一源码清单。

### 用户实机反馈

用户回复：“手测我没测出什么问题，我给手测版本的退了”。核对手测 PID 已退出；隔离设置已保存两个实例（原先三个，删除了一个），两者均恢复穿透，保存了显著缩放及含负坐标的位置。将此记录为用户手测总体未发现问题；没有录屏或逐项日志，不据此声称已自动验证 Finder/Space/Stage Manager/物理拔屏。当前三屏均为 2×，1× 显示器仍未覆盖。

### 正式 0–4 基线已完成

`python3 scripts/benchmark.py` 所有 5 个场景均 Exit 0，每组预热 4 秒后 300 秒静止目标 + 120 秒 1Hz 合成移动目标。以下 CPU 为本进程 getrusage，100% 代表一个核心；内存为样本均值，含本机框架/窗口/纹理/JSC，不等同于纯模型内存。

| 实例 | 时长 s | 静止 CPU % | 移动目标 CPU % | 常驻 MiB | 物理占用 MiB | 各实例实际 FPS |
|---:|---:|---:|---:|---:|---:|---|
| 0 | 420.0 | 0.59 | 0.85 | 56.0 | 20.8 | — |
| 1 | 420.0 | 28.21 | 21.77 | 88.6 | 177.2 | 29.92 |
| 2 | 420.0 | 23.25 | 22.95 | 108.7 | 225.5 | 29.91, 29.91 |
| 3 | 420.0 | 36.01 | 38.40 | 138.3 | 263.7 | 29.83, 29.83, 29.83 |
| 4 | 420.0 | 44.62 | 43.73 | 154.7 | 297.7 | 29.84, 29.84, 29.84, 29.84 |

这些数据来自正在使用的工作站；期间其他应用、用户手测以及隔离候选的编译/验证可能并发，CPU 不应被解释为严格单调的实例增量定律。1→2 实例 CPU 下降说明时段/模型差异与系统调度噪声不可忽略；内存增量则约为首次 +32.6 MiB resident / +156.4 MiB footprint，随后分别 +20.1/+48.3、+29.6/+38.2、+16.4/+34.0 MiB。没有用不同数量/资源的数据宣称胜过其他播放器。

长时基线使用已固定并记录 SHA 的早期稳定构建；后续候选保留相同旧版模型渲染路径，增加原生更新顺序修正、边界和诊断。正式产物已重建（Exit 0），后续 profiling 针对当前产物。

### 最后回归

`.local/verification/release-integration/`：152 项集成检查、17 项新进程恢复检查通过，约 30.00 / 59.52 FPS；新增记录整个实例生命周期中瞬时 GL error 计数，存活实例均为 0。离屏窗口经屏幕变化通知回到可见区域。缩放达到窗口最小/最大尺寸后仍保持一个共同缩放比例，避免反复放大缩小时纵横比漂移；几何边界单测通过。

### 压力之后的 Leaks 与工具附加问题

- `python3 scripts/leaks_after_stress.py` Exit 0：先通过 152 项集成检查（含 30 次增删、20 次替换），在 30 秒的静止保留窗口扫描同一存活进程。`leaks` Exit 0，报告 `0 leaks for 0 total leaked bytes`，应用最终 Exit 0。记录 `.local/verification/post-stress-leaks/run-20261102-010319/`。该结果不代表能证明不存在任何未来模型或驱动泄漏。
- 最初的串行热附加流程在 Allocations 后停止推进采样，整体看门狗退出，故不计为正常完成。单独复现的线程采样显示 JSC 调用与 Instruments 注入的 liboainject 栈。改用每个模板启动新进程：Allocations 已正常取得记录，目标约 29.60 FPS / GL errorCount=0，正常自动退出。
- `scripts/profile_app.py` 已改为每模板独立 launch、检查应用自身 summary 与目标退出状态，并清理该次 Instruments 遗留的项目内停止占位进程；不以单独 xctrace Exit 0 作为应用成功证据。
- Power Profiler 实际报错：`The Power Profiler instrument is not supported on macOS. Record on iOS or iPadOS instead.` 未把此工具输出当作有效能耗数据；正在使用 macOS Activity Monitor 模板核对可用指标。
