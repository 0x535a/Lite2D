# Companion 按需 SDK 架构与资源验证

2026-11-05，已安装版本 1.2.0（build 11）。目标是降低常驻成本，保留原有功能，不要求所有源码改为 Swift。

## 实际运行结构

- 现有 AppKit/SwiftUI 应用内的 `NativeCompanionRuntime` actor 常驻：调度、计时、角色状态、预算、队列、取消、SQLite 和观察缓存，不再另起 Controller 进程。
- OpenCode 使用 Swift `URLSession`，用户工作服务只读，角色使用自己的鉴权服务；Codex 通过原生子进程与固定 JSON-RPC 白名单观察，不 resume 用户线程。
- MCP 使用应用自身的 `--companion-mcp` 无窗口入口，不初始化模型渲染或 NSApplication。角色互聊和记忆工具不需要 Node。
- Claude 会话解析继续交给官方 `@anthropic-ai/claude-agent-sdk@0.3.318`。应用只在确需读取时启动 `claude-helper.mjs`；它仅提供 list/info/recent 三种读取，不 query、不生成、不管理状态或预算。
- Swift 使用 FSEvents 监听目录路径和文件变化，不自行解析 JSONL 正文。SDK 负责会话链、compaction 与历史读取的兼容性。

Node 仍是 Claude 历史读取的可选运行依赖。未启用 Claude 时，OpenCode/Codex、角色交流、记忆和界面可以不安装 Node。OpenCode/Codex 自身的服务进程仍存在，不能将其资源计入“已消除的 Node 开销”。

## 生命周期与变化检测

SDK 助手按 `stopped → starting → ready/busy → idle grace → stopped` 运行。连续请求复用，同一请求合并；最后一次请求完成、没有进行中或排队工作后开始 60 秒空闲计时。超时退出，没有周期重启任务。来源关闭、应用退出或权限撤回会停止助手，并丢弃迟到结果；崩溃后指数退避，避免反复冷启动。

启用 Claude 时先建立 watcher，再做 SDK 列表基线。后续 Swift 先合并变化，通常等待约 2 秒安静窗口，持续写入最长约 30 秒归并；普通观察调度检查缓存与 dirty 标记，不因每 15 秒轮询而启动 Node。首次历史不补播。休眠唤醒或 FSEvents 丢事件后做一次 SDK 对账。勿扰、预算用尽或没有可发言角色时不反复加载正文；角色按需查看历史仍使用 SDK。

`NativeCompanionStore` 使用原来的 SQLite 表、JSON 编码与 Session ID。未更换 Persona 或清空记忆；导出文件仍是投影，公共记录保留 expectedRevision 与作者审计。状态/计时通知不再重复写进数据库，防止把大批会话列表不断复制为事件日志。

共享提示词仍在 `Companion/prompt.mjs` 集中编辑，构建时逐字导出 `prompt.json` 给 Swift；构建工具依赖 Node 不代表运行时常驻 Node。工具权限和白名单不由提示词控制。

## 功能等价证据

- `python3 scripts/test_native_companion.py`：28 项原生检查，包括 SDK 冷启动/复用、并发去重、空闲退出、安静轮询不唤醒、FSEvents 变化触发、权限撤回、崩溃退避、记录冲突、预算、手动触发与取消。
- 同一脚本使用真实 OpenCode 引擎、原生 MCP 和本地确定性上游：两个独立 Session 实际调用各自工具并交换消息；回复持久入队，不额外启动一轮生成；重启恢复原 Session 和记忆，再消费待同步回复。工具续轮的请求数正确，交流期间 Node 助手启动次数为 0。
- 真实已配置模型与提供的 22/33 Persona：Swift 接入三种全局会话来源均 available，两角色分别真实生成问候；SDK 助手一次启动后正常空闲退出。此项是外部模型验收，不与确定性协议夹具混淆。
- 约 275 MiB 的旧数据库一致性快照经原生运行时打开/关闭，state、records、events、changes 的行数与内容哈希均不变；3861 条旧事件和原 Session 关联保留。
- `python3 scripts/test_companion.py` 通过原有 26 项原生界面、气泡位置、测试按钮与对视验收；四语 289 键通过。全程不用 computer use，不驱动桌面鼠标键盘。

## 受控短测结果

以下为本机单轮有界比较，不是长期统计保证。旧版与新版使用同一 SDK、10 个合成会话、相同读取请求序列及来源开关；各运行 90 秒，包含一次请求突发和超过 60 秒的空闲期。只统计各自的完整受测进程树；没有真实模型网络请求。CPU 时间根据本机 Mach timebase 校准。footprint 合计与 RSS 合计都分项保留，不能当作系统唯一物理 RAM。

| Controller 场景 | 旧版常驻 Node | 新版 Swift＋按需 Node |
| --- | ---: | ---: |
| 空闲 footprint 合计均值 | 49.4 MiB | 5.1 MiB |
| 空闲 RSS 合计均值 | 59.5 MiB | 11.0 MiB |
| 活跃 footprint 合计峰值 | 54.0 MiB | 47.3 MiB |
| 活跃 RSS 合计峰值 | 78.1 MiB | 95.1 MiB |
| Controller ready | 258 ms | 37 ms |
| SDK 首次读取（ready 后） | 2.8 ms | 88.0 ms |
| SDK 复用读取 | 4.6 ms | 1.0 ms |
| 活跃采样段 CPU 时间 | 0.0268 s | 0.0281 s |
| 末段约 9 秒 CPU 时间 | 0.00184 s | 0.00019 s |
| 空闲 Node 进程数 | 1 | 0 |

旧版在 ready 前已加载 SDK，因此不能单看 SDK 首次读取就比较整体冷启动。新版付出一次约 88 ms 的助手冷启动，后续复用；90 秒内共处理 14 个 SDK 请求，仅启动一次助手。活跃 RSS 峰值有所上升，CPU 活跃耗时没有证实改善，不能声称所有指标都更低。

另做整个播放器应用的顺序短测：相同两个本地模型、30 FPS、相同布局、鼠标跟随关闭、相同合成 Claude 记录、角色生成关闭，各 75 秒；比较超过助手宽限后的最后 10 个采样点。

| 整个应用进程树空闲场景 | 旧版 | 新版 |
| --- | ---: | ---: |
| footprint 合计均值 | 253.9 MiB | 204.8 MiB |
| RSS 合计均值 | 191.5 MiB | 139.1 MiB |
| 末段约 9 秒 CPU 时间 | 3.25 s | 3.38 s |
| 进程 | 应用＋Node | 仅应用 |

此场景减少约 49.1 MiB footprint 合计（约 19%）；渲染占主要 CPU，未证实 CPU 改善。SDK 冷启动/活跃 RSS 的折衷保留在表中，不能用“语言更原生”代替实测。

复现：

```sh
sh scripts/build.sh
python3 scripts/test_native_companion.py
python3 scripts/test_companion.py
python3 scripts/test_localization.py
python3 scripts/profile_companion_runtime.py --seconds 90
python3 scripts/profile_companion_app.py --seconds 75
```

原始计数、逐进程采样与数据兼容哈希在忽略目录 `.local/verification/swift-migration/`。旧 JavaScript Controller 与其测试暂保留作行为/性能基线，但不进入应用包，也不参与新运行时。

安装到 `/Applications/Lite2D.app` 后，核对了资源/可执行文件哈希与签名，原设置和 Persona 未改写；旧应用和数据库可从 `.local/installation-backups/` 回退。连续 72 秒观察中，应用仍在运行，没有旧 Node Controller，也没有空闲后重启的 Claude 助手。
