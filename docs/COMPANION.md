# Companion v1

Companion 是 Lite2D 的可选主动陪伴功能。原有模型实例、窗口、显示器绑定和播放设置继续由 Swift/AppKit 宿主管理。禁用 Companion 时不在后台运行 Controller 或角色 Agent；用户打开交流记录窗口时，可临时启动仅提供记录读写的服务，关闭窗口后退出，不唤醒角色。

## 配置

1. 角色设置 → 陪伴 → 选择 Persona Markdown，再启用此角色。每个模型实例一对一绑定独立文件、Session 和私有记忆；不建立人格模板库。
2. 通用设置 → 主动陪伴 → 开启服务。根据实际可用的 OpenCode provider 填写 `provider/model`，可留空使用默认值。
3. 在工作观察中分别启用 OpenCode、Codex、Claude Code。启用即覆盖该来源在本机可读取的全部会话，跨项目与 Git worktree，并包括接口可枚举的归档记录；旧版项目列表迁移为来源开关。默认新配置关闭来源。
4. 设置闲聊间隔：0 为关闭，可选择快捷值或用步进器调整。关闭闲聊后，工作事件仍可产生评论；勿扰会停止生成和展示。

Swift 调度、SQLite、OpenCode HTTP、Codex JSON-RPC 和 MCP 在原生侧运行。仅 Claude 官方历史 SDK 使用按需 Node.js 24+ 助手，连续读取复用，空闲 60 秒后退出；没有变化不会每 15 秒重启。设置页可覆盖 Claude 助手的 Node 路径及 OpenCode/Codex 路径。CLI 更新后应重新验证协议。SDK 客户端随应用提供，不在用户机器上运行 npm install。

Companion 主开关开启时，Swift 每 5 秒检查 OpenCode 后台服务；如果服务已停止或注册失效，会通过官方 CLI 自动启动，并在 **主动陪伴设置** 显示检查中、启动中、运行中、启动失败及 PID/版本。关闭 Companion 会停止监控但不关闭 OpenCode，工作会话不会被中断。服务启动失败显示原因并退避重试，不把“文件不存在”之类的内部错误直接暴露给用户。

## 人设与动机

Persona 使用自由 UTF-8 Markdown，不需要 front matter；上限 64 KB。导入保存独立副本，通过「编辑 Markdown」修改，下一回合重新加载。修改人设不清空原有记忆。若同目录有本项目示例包的 `original_style_corpus.jsonl`，导入器可为已声明的 22/33 复制对应说话人的原创风格示例；每次生成只选少量相关场景，并标记为风格素材，不当作共同经历或官方原话。不会执行 Persona 包里的脚本或自动下载外部资料。

每个角色的「陪伴」页提供 **触发一次对话**：立即唤醒选中的模型实例，要求按 Persona 给一句简短问候或与同伴交流，不提供用户聊天输入。手动测试跳过定时等待，仍要求角色可见、陪伴与角色已启用、勿扰关闭、无其他话题且有剩余额度；若选择安静会显示提示。

同一页的 **对话气泡 → 调整位置…** 会显示一份可拖动的预览气泡。拖动后点 **完成** 保存相对模型窗口的位置；模型移动、拖动或缩放时气泡跟随。普通台词气泡仍为不激活、不截获点击的浮层，只有调整预览接受鼠标。位置按模型实例独立保存，换装保留，可重置为默认上方位置；复制模型不共享该位置。

工作进展、同伴消息和闲聊定时器提供思考机会。人格、兴趣、真实共同记忆和未完话题决定表达内容；无话可说时返回 skip。不会因为定时器到点就强迫寒暄，也不会因为没有键盘活动而断言用户疲惫或情绪低落。

首版全局一次只运行一个自主话题，初始冷却为 3 分钟；每话题最多 4 条台词、90 秒。每次角色生成、工具后的继续生成与检测到的 provider 重试使用共享小时预算。OpenCode 内部 compaction 与 provider 行为由其自身管理，预算不应被解释为精确费用承诺。provider 连续失败会停止本次话题。

## 权限与观察

- 角色 OpenCode 服务为专用鉴权 loopback 进程，用户工作 Session 仅通过只读适配器观察。
- 角色默认拒绝所有工具，仅开放已认证的 Companion MCP 工具。实际 OpenCode 权限验证覆盖 shell、execute、edit、write、external_directory 的拒绝，不开放审批绕过入口。
- Controller 会启动自己的 CLI/服务子进程；「角色不能执行 Shell」不代表宿主无法启动提供功能所需的程序。
- provider 配置通过本机配置读取，服务连接头与 provider 认证不打印到台词、时间线或配置表单。角色目录中的 MCP 连接令牌为应用生成的本地工具令牌，权限绑定固定实例 UUID。
- 只读适配器没有 prompt/resume/steer/abort/delete 等通用代理。Codex 使用 `useStateDbOnly:true` 和 turn 分页，不调用当前运行时不支持的 item 分页。
- 三种来源每 15 秒轮询，分页枚举全部可用会话，排除本应用自己的角色 Session；每次读取有限近期/已变化的尾部，不全量加载所有正文，其他历史可通过只读工具按需查看。首次建立基线不补播旧历史。更新由有限近期内容的变化判断，不把 `notLoaded` 或目录更新时间解释为真实活动状态。
- Claude SDK 会从 transcript 构建会话链，结果分页不是低成本文件 tail。Swift 只监听路径变化、合并 dirty 标记，不自行解析 JSONL；确需读取时才唤醒 SDK 助手。大量历史的读取成本和跨进程落盘时延仍取决于 SDK/CLI。
- 关闭来源后清除对应观察缓存与待触发话题。内容会做限长和常见凭证过滤，但这不能保证识别任何形式的秘密；请仅启用希望角色了解的来源。

## 呈现与恢复

气泡是原生非激活面板，保留模型点击穿透，不抢输入焦点。按台词长度排队显示，历史保留完整文本。交流双方使用现有 lookX/lookY 平滑管线看向彼此；结束、停止、隐藏、休眠或断线时释放覆盖，不修改 trackingEnabled。模型缺少眼球/头部参数时，实际效果受资源能力限制；当前脸部锚点为窗口约 50%/70%，不同模型可有视觉偏差。

匹配模型真实表情名称时可应用瞬时情绪，结束后恢复用户设置；不猜测不存在的 motion ID。不做 TTS、音频、口型或用户聊天输入。

数据位于 `~/Library/Application Support/Lite2D/Companion/`。SQLite 保存投递状态、版本、修改者、调度预算与时间线；`persona.md` 是用户人设源，私有记忆/公共记录/近期交流另有 Markdown 导出。记忆请通过应用编辑，导出不是第二个写入入口。私有记忆编辑不等于抹除旧上下文；「清空记忆并开始新会话」解除旧 Session 关联，后续使用新 Session，旧历史仍在 OpenCode 存储中。

角色消息先持久化并显示，再排队投递。对方回应来自自己的 Session；回送原角色使用 `resume:false` inbox 接纳，不为收尾强制触发新生成。接纳、消费、失败与不确定状态分别记录，崩溃后不盲目重发。记录写入在 SQLite 事务中进行 expectedRevision 检查与审计，冲突要求重读合并。

## 验证

- `python3 scripts/test_native_companion.py`：Swift 调度、存储、SDK 助手生命周期与 FSEvents、真实 OpenCode/原生 MCP、独立 Session、预算、非生成回送与重启。旧 JavaScript 测试保留作基线，不作为新运行时验收。
- `python3 scripts/test_companion.py`：应用内加载模型、四语页面、气泡、双方对视、拖动、取消与持久设置保持；不使用 computer use 或外部应用自动化。
- `LITE2D_CAPTURE_OWN_WINDOW=1 python3 scripts/test_companion.py`：额外记录仅本应用测试窗口的系统合成截图，用于核对原生控件布局；不操作桌面输入。
- `python3 scripts/test_localization.py`：四语资源、占位符与即时切换。

真实 provider 与提供的 22/33 人设的双角色验收另记于 `TEST_REPORT.md`。本地确定性模型夹具仅用于验证引擎协议，不冒充外部模型的实际生成。

常驻结构、资源对比与已知折衷见 [COMPANION_RUNTIME.md](COMPANION_RUNTIME.md)。
