# Lite2D Companion controller

Node.js 24+ child process for the Swift/AppKit host. No browser, TTS or user chat input.

```sh
npm ci --prefix Companion --ignore-scripts
node --test Companion/controller.test.mjs Companion/native.test.mjs
sh scripts/build.sh
python3 scripts/test_companion.py
```

`main.mjs` accepts JSON lines on stdin and emits versioned events on stdout. Diagnostics use stderr. Closing stdin stops only its own Codex observer and OpenCode role service. The native host detects Node in PATH, Homebrew and nvm; executable overrides are available in General Settings.

Role Personas are individual UTF-8 Markdown files. The Controller starts a dedicated authenticated OpenCode loopback service, inherits only provider configuration and allows only its per-character MCP tools. It never uses the user's work sessions for generation. Model requests are charged to a shared rolling-hour budget; tool continuations reserve their next request and provider retries are counted. OpenCode still controls its own compaction and inference internals, so this is not a billing guarantee.

Enabled source adapters enumerate all locally readable conversations across projects and worktrees, including archives exposed by each backend. Legacy project grants migrate to source toggles. Metadata pages are fully enumerated; bounded recent/changed tails are read per poll and other histories are available on demand. Codex uses `useStateDbOnly:true`, metadata reads and turn pagination; it never resumes an observed thread. Claude uses official SDK transcript functions without `query()`. Its pagination is not a filesystem-tail API. All sources are polled at 15-second intervals, and recent bounded content is compared even when list timestamps stay unchanged. Initial results establish a baseline without speaking. Per-model test buttons target one specific character and bypass the idle timer, while honoring pause, visibility, busy state and the shared request budget. Corpus examples, observed logs, shared records and peer messages are quoted context, never elevated instructions.

SQLite is authoritative for memory versions, audit, delivery states, quotas and the visible timeline. Readable Markdown projections are written under `characters/<id>/memory.md`, `public/records` and `public/exchanges`. Change memory in the app's editor; these exports are not a second write channel. A crash during delivery becomes `delivery_unknown`, not an automatic resend. A reply accepted with `resume:false` stays in the source character's persistent inbox until its next allowed generation consumes it.

`native.test.mjs` uses the real installed OpenCode engine and a local deterministic upstream to test separate sessions, direct scoped MCP tools, reply routing, budget accounting, restart and disabled shell/file/code execution. It does not claim that a remote model provider is available. Live-provider acceptance is recorded separately in `TEST_REPORT.md`.

Private model data and provided Persona packs are not bundled in the app or source distribution. The build bundles only the controller's read-only client dependencies and MCP entrypoint; no Claude CLI binary is bundled.
