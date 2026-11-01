# 公开前隐私与许可审计

审计日期：2026-11-02。范围为根仓库截至 `cf9cc73` 的全部可达历史（13 个提交、119 个不同文件 blob）和本次拟提交快照；官方 SDK submodule 仅保留上游引用。不包含任何已公开远端操作。

## 隐私与凭据

| 项目 | 结果与处理 |
|---|---|
| 历史凭据扫描 | Gitleaks 使用脱敏输出扫描全部可达历史，无命中；只说明规则未检出，不保证不存在所有形式的敏感信息 |
| 文件中的个人信息 | 规则检查未命中真实个人主目录、已知设备序列号、硬件 UUID 或常见私钥/令牌格式 |
| Git 作者与提交者 | 历史包含真实署名、非 noreply 邮箱；用户明确选择保留。不将仓库描述为匿名化，不改写历史、不改全局 Git 配置 |
| 个人工作流 | 当前脚本移除了对其他本地项目的默认路径依赖，测试夹具使用通用别名，工坊选择须显式传入；旧提交中的测试记录/原工作流说明仍可读取，本次未重写历史 |
| 图标资产 | SVG/JSON 源未发现个人路径或署名元数据；README PNG 已移除 EXIF/XMP/文本元数据，保留图像与色彩信息 |
| 本机二进制 | 当前产物检查未命中个人主目录字符串；这不是二进制隐私或发行许可的全面认证，产物仍不进入公开源码 |

## Git 边界

`doc/`、`.local/`、`build/`、`dist/`、专有旧版运行库及模型二进制保持忽略。补充忽略本地环境文件、签名材料、诊断日志与 trace；保留 `.env.example` 的可提交性。审计未在可达历史中发现个人模型、Core 静态库/动态库或这些私有目录被提交。

本地测量日志、模型来源收据、旧路径、渲染捕获和设置副本仍可能包含私人信息，**忽略不等于文件已从本机删除**。公开应使用 Git 提交快照；不要直接压缩整个工作目录，也不要把这些目录加入 Release 附件。Git 远端地址和本机 Git 配置不属于提交快照。

## 许可与发布决策

- 用户选择：项目自有代码使用 MIT，保留现有 Git 署名/邮箱。根目录 `LICENSE` 不覆盖第三方 SDK、模型、专有库或第三方衍生内容。
- 官方 [Expandable Applications](https://www.live2d.com/en/sdk/license/expandable/) 页面明确：具备不定数量模型扩展能力的应用需要发布前审查和特殊 Publication License Agreement；并不能因免费、开源而自动豁免。
- [Live2D Open Software License](https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html) 的 Publish / Distribute 定义较广。不能将“只公开源码、不附 Core”视为已经确认的许可豁免；源码公开方式与可执行包发行都应核实适用条款。
- 官方 Samples/Framework 使用上游 submodule 和原许可；Core、旧运行库、第三方模型均未获得本项目 MIT 再许可。具体说明见 `THIRD_PARTY_NOTICES.md`。

因此，本次完成的是图标集成、源码当前快照清理和可重复审计；不宣称已获得 Live2D 发布授权。**没有切换远端可见性、push/force-push、改写 Git 历史或上传 `.app`。**

## 验证与记录

构建仅用于确认图标打包和签名；没有重新运行模型压力测试。应用资源包含 `Assets.car` 与 `AppIcon.icns`，Info.plist 指定 AppIcon，README 使用仓库内 PNG 预览。

历史/索引凭据扫描、PNG 元数据、构建与签名记录保留在忽略的 `.local/verification/public-audit/`。文件中的版本哈希、SDK ZIP 校验和、公开上游 URL 和通用测试夹具名是可复现技术信息，不作为凭据删除。
