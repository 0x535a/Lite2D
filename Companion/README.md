# Companion shared prompts and on-demand Claude helper

The production Controller is a Swift actor inside the app (`App/NativeCompanionRuntime.swift`). OpenCode HTTP, Codex JSON-RPC, memory, quotas and MCP are native. `claude-helper.mjs` only wraps the official Claude history SDK; Swift owns request coalescing, FSEvents dirty tracking, timeout/backoff and 60-second idle shutdown. No permanent Node Controller is shipped.

`prompt.mjs` remains the single editable source for shared wording. Build-time export creates `prompt.json` for Swift with verbatim strings; Persona Markdown stays user-owned and unchanged. The build bundles only the read-only Claude helper and its notices, never the Claude executable. OpenCode/Codex and role conversations do not require Node.

```sh
sh scripts/build.sh
python3 scripts/test_native_companion.py
python3 scripts/test_companion.py
```

Files in this directory:

| File | Purpose |
| --- | --- |
| `claude-helper.mjs` | Read-only SDK worker; supports list/info/recent only. |
| `prompt.mjs` | Shared model instructions and tool descriptions. |
| `build.mjs` | Bundles the worker and exports `prompt.json` and dependency notices. |
| `package.json`, `package-lock.json` | Pinned SDK and build dependencies. |

To build only these resources, run `npm ci --prefix Companion --ignore-scripts` then `npm run build --prefix Companion -- /absolute/output/directory`. `npm test --prefix Companion` runs the current native test suite and requires a built app at `dist/Lite2D.app`.

The former JS Controller, adapters, MCP implementation and tests have been removed. Their last retained baseline is commit `007efd1`; use a separate checkout of that commit for historical comparisons. Current runtime code and tests live in `App/NativeCompanion*.swift`, `App/NativeClaudeHelper.swift`, `App/NativeOpenCodeServiceMonitor.swift` and `Tests/NativeCompanionTests.swift`. Details, historical measurements and limits: [runtime review](../docs/COMPANION_RUNTIME.md).
