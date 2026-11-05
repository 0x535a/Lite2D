# Companion shared prompts and on-demand Claude helper

The production Controller is a Swift actor inside the app (`App/NativeCompanionRuntime.swift`). OpenCode HTTP, Codex JSON-RPC, memory, quotas and MCP are native. `claude-helper.mjs` only wraps the official Claude history SDK; Swift owns request coalescing, FSEvents dirty tracking, timeout/backoff and 60-second idle shutdown. No permanent Node Controller is shipped.

`prompt.mjs` remains the single editable source for shared wording. Build-time export creates `prompt.json` for Swift with verbatim strings; Persona Markdown stays user-owned and unchanged. The build bundles only the read-only Claude helper and its notices, never the Claude executable. OpenCode/Codex and role conversations do not require Node.

```sh
sh scripts/build.sh
python3 scripts/test_native_companion.py
python3 scripts/test_companion.py
```

The former JS Controller, adapters and tests remain temporarily as the old/new behavioral and performance baseline. They are not bundled or started by the app. Details, measurements and limits: [runtime review](../docs/COMPANION_RUNTIME.md).
