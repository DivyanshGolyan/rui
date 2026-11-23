Research map, nothing built. Asked for by Divyansh on 2026-11-23: where can Rui's small footprint (many agents in one small process, survives crashes) let a person start with close to zero friction, even where it takes real development to get there?

## The short answer

Today a terminal user pays three costs before the first answer: **install** (one curl line, about 30 s), **sign in** (ChatGPT or an API key), and **run**. The install is already small. **Sign-in is the step worth removing**, and the cheapest way to remove it is a model the person already has: Apple's models on their Mac, GitHub Models through the GitHub token they already have in CI, or a local model server.

Recommended order (sizes are guesses):

| # | Surface | Friction removed | Dev cost | Why now |
|---|---|---|---|---|
| 1 | **Spike: Apple Foundation Models in the Mac TUI** (on-device model + Private Cloud Compute) | Sign-in and paying, on every Apple Intelligence Mac | 2-3 day spike, then ~3-5 wk | Apple ships a C binding; PCC is free to developers and billed to the user's iCloud; 32K context with tool calling |
| 2 | **Rui as a GitHub Action using GitHub Models** | All secrets in CI (`permissions: models: read`) | ~1-2 wk (needs a Chat Completions codec) | No key to create; repo owners already trust Actions |
| 3 | **Local model servers** (Ollama, LM Studio, Foundry Local, llama.cpp) | Sign-in and cost, offline | ~1-2 wk (HTTP/1.1 provider transport) on top of #1862 | Rui's request is already stateless (`store:false`), which is what Ollama's Responses endpoint supports |
| 4 | **Linux arm64 release** | "Not supported on my machine" for Pi, Graviton, Chromebook Linux, Termux+proot | days | The transport build already knows `aarch64-linux` |
| 5 | Thin launchers: Raycast, VS Code (borrow Copilot via `vscode.lm`), Zed/ACP | Leaving the tool you live in | 1-2 wk each, after the Host protocol work | Mostly wrappers that spawn `rui` |
| — | Browser page or extension on Chrome's Gemini Nano | Install and sign-in | 6-10 wk browser port + tool emulation | **Not now**: desktop only, 22 GB free disk, no tool calling, no Bash |
| — | iOS app / Shortcuts step on Apple Intelligence | Install on phones | months | **Not now**: no Bash or subprocesses on iOS, App Intents get ~30 s; needs client-run tools first |
| — | Android (AICore), watches, routers, cloud functions | — | — | **Not now**, reasons below |

The single most valuable next step is the **Apple spike**: can a signed, non-App-Store command-line program call the on-device model and PCC through Apple's `foundation-models-c` library, with tools, and does Rui's prompt fit? If yes, "install Rui on a Mac and start typing, no account" becomes real.

## How the space was searched

Every candidate is one choice on each of five axes. I walked each axis fully, then kept only combinations where Rui's nature adds something.

1. **Where the model comes from** (this decides sign-in): vendor account (ChatGPT, API key) · OS-bundled on-device model (Apple, Chrome Gemini Nano, Android AICore, Windows Phi Silica) · OS-vendor cloud billed to the user's existing account (Apple PCC) · a token the person already holds (GitHub `GITHUB_TOKEN`/`gh`, Copilot via VS Code, MCP sampling from a host app) · local server they run (Ollama, LM Studio, Foundry Local, llama.cpp) · in-page model (WebLLM/WebGPU).
2. **Device**: macOS arm64 · Linux x86-64 · Linux arm64 (Pi, Graviton, Chromebook) · Windows (via WSL today) · iPhone/iPad · Android · browser tab · watch · router/embedded · CI runner · cloud function/container.
3. **Host program**: terminal TUI · script/TypeScript (`ruicode`) · browser page · browser extension · Shortcuts/App Intents · launcher (Raycast, Alfred) · editor (VS Code, Zed via ACP, JetBrains) · MCP host (Claude Desktop, Cursor) · GitHub Action.
4. **Mode**: signed-in · no-login · offline · embedded library · WASM.
5. **Distribution**: curl installer · npm (`npm install ruicode`) · Homebrew · App Store · Chrome Web Store · Raycast Store · GitHub Marketplace action · Docker image.

For each I judged: friction removed (which of install / sign-in / run disappears), fit with Rui's architecture (read from `src/`), platform limits (memory, run time, context window), and dev cost.

## What Rui's architecture allows (read in source)

- **Model access is HTTP/2 only.** `src/provider.zig` drives every model request through the `h2` client (nghttp2 + OpenSSL). Cleartext is allowed only to loopback (`src/providers.zig` `InsecureKeyEndpoint`). Ollama and LM Studio speak HTTP/1.1, so they need an HTTP/1.1 provider transport. Rui already has an HTTP/1.1 parser for its own protocol (`src/http1/`).
- **One wire format today**: `openai-responses` (`src/codecs/responses.zig`) behind a codec contract (`src/codec_abi.zig`). A codec is a pure function set, so new formats (Chat Completions for GitHub Models, an Apple transcript format) fit the existing seam.
- **Requests are stateless** (`"store":false` in the request envelope), matching Ollama's Responses endpoint, which supports tools but not `previous_response_id`.
- **Providers are a closed list** (`codex`, `chatgpt`, `openai`); #1862 (named connections, part of #1858) replaces it and is the natural home for "local server" and "Apple" connections.
- **Model instructions are 14-22 KB** (`src/model_instructions/*.txt`), roughly 4-6K tokens before tools and history. That alone fills most of Apple's 8K on-device window; PCC's 32K is workable with compaction.
- **Platforms**: Linux x86-64 and macOS arm64 ship. `src/build_transport.sh` already handles `aarch64-linux`; WSL users already run Rui (#1886).
- **Bash is the main tool**, so any surface with no subprocesses (iOS, browser) needs client-run tools, the gap the Host embedding design named (`/mnt/project-files/rui-host-embedding/README.md`).
- **Browser build**: prior study (`/mnt/project-files/rui-in-browser/study.md`, 2026-11-12) found ~62/303 source files touch the OS and guessed 6-10 weeks.

## Each candidate

### 1. Apple models in the Mac TUI (recommended spike)

Facts (Apple primary sources, read 2026-11-23):
- On-device model context: `4096 on 26.0`, `8192 on 27.0 (newer devices)` ([WWDC26 #319](https://developer.apple.com/videos/play/wwdc2026/319/)).
- **Private Cloud Compute model for developers**: 32,768-token context, reasoning levels, tool calling and structured output "work just the same" as on-device. "No token costs to you, the developer"; usage is counted against the user's iCloud account with a daily limit (higher with iCloud+), number not stated. Available to apps with fewer than 2M downloads, by application ([#319](https://developer.apple.com/videos/play/wwdc2026/319/), [#241](https://developer.apple.com/videos/play/wwdc2026/241/)).
- macOS 27 ships an `fm` command-line tool that reaches both the on-device model and PCC; output is JSON on stdout, `--schema` for structured output ([WWDC26 #334](https://developer.apple.com/videos/play/wwdc2026/334/)).
- Apple publishes a **C binding**: `foundation-models-c` inside [apple/python-apple-fm-sdk](https://github.com/apple/python-apple-fm-sdk) (macOS 26+, Apple Intelligence turned on). Zig can call C directly.

What it takes: an in-process model adapter (no HTTP) through the C binding, a codec mapping Rui's neutral items to Apple's transcript and tools, a smaller instruction set for small windows, and compaction tuned for 8K/32K.

Unknowns the spike must answer: (a) does the PCC entitlement work for a signed command-line program distributed outside the App Store, or only for app bundles? (b) does the C binding expose tool calling and PCC, or only on-device text? (c) does a real Rui turn with Bash fit and behave in 8K / 32K? (d) daily quota size in practice. Users without Apple Intelligence (Intel Macs are already unsupported; Apple Intelligence also has region and language limits) fall back to today's sign-in.

Why it suits Rui: the model costs nothing per call, so many agents on one Mac become free to try; crash safety and never repeating a command still apply unchanged.

### 2. GitHub Action on GitHub Models

Facts: a workflow with `permissions: models: read` can call `models.github.ai/inference/chat/completions` with `GITHUB_TOKEN`; the restricted default token and PRs from public forks get no `models` access ([GitHub quickstart](https://docs.github.com/en/github-models/quickstart), [GITHUB_TOKEN permissions](https://docs.github.com/en/actions/automating-your-workflow-with-github-actions/authenticating-with-the-github_token)). Free use is rate-limited per model and per day ([billing](https://docs.github.com/en/billing/concepts/product-billing/github-models)). I found no Responses endpoint, so this needs a Chat Completions codec (guess, not verified).

Fit: Linux x86-64 runner, Bash available, SQLite Store in the workspace; one process can run many agents over a repo. Also works locally for anyone with `gh auth token` if the token has `models:read` (unverified for classic `gh` tokens).

### 3. Local model servers

Facts: Ollama serves `POST /v1/responses` with tools and streaming, stateless only, since v0.13.3 ([Ollama docs](https://docs.ollama.com/api/openai-compatibility)). Microsoft's Foundry Local exposes an OpenAI-compatible endpoint on any Windows hardware ([Microsoft](https://learn.microsoft.com/windows/ai/overview)); Windows itself is WSL-only for Rui.

Needs: HTTP/1.1 to loopback in the provider transport, plus #1862 connections. Friction: the person must install the server and pull a model (GBs), so this serves people who already have one. Small local models handle tool calls unevenly (not measured).

### 4. Linux arm64 release

Earlier device study (`/mnt/project-files/rui-device-market/`) cross-built with `-Dtarget=aarch64-linux-gnu.2.34`. Opens Raspberry Pi, Graviton/Ampere servers, Chromebook Linux, and Termux via `proot-distro` (plain Termux is bionic libc and blocks exec from app data above targetSdk 28, so a glibc build only runs inside proot; [Termux wiki](https://www.github.com/termux/termux-packages/wiki/Termux-and-Android-10)). Cost: a release target and CI time; the CI cost rule applies.

### 5. Launchers and editors

- **Raycast**: its built-in AI API needs Raycast Pro ([Raycast docs](https://developers.raycast.com/api-reference/ai)), so no free model; an extension could still spawn `rui` with the user's sign-in. Saves a terminal switch only.
- **VS Code**: extensions can call the user's Copilot models through `vscode.lm` with tool calling ([VS Code docs](https://code.visualstudio.com/api/extension-guides/ai/language-model)). Whether Copilot Free users get models there is not documented (unverified). That would let Rui run on a model the person already pays for, but needs a provider that calls back into the extension, i.e. client-run model calls.
- **Zed / JetBrains via ACP**, **MCP hosts**: already the recommended first client in the Host-sides study. MCP sampling would let a host lend its model, but the spec requires the host to show each request to the user, and which hosts implement it is unverified.

### Not now, and why

- **Chrome Gemini Nano (web page or extension)**: the Prompt API is in Chrome 148 for web pages and Chrome 138 for extensions; desktop only ("Chrome for Android, iOS ... not yet supported"); 22 GB free disk; >4 GB VRAM or 16 GB RAM; English, Japanese, Spanish, German, French; not in Web Workers; structured output via `responseConstraint` but **no tool calling documented**; context window size not published ([Chrome docs](https://developer.chrome.com/docs/ai/prompt-api), [built-in APIs](https://developer.chrome.com/docs/ai/built-in-apis)). Extension service workers stop after 30 s idle ([Chrome](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)). With no Bash and a browser port costing 6-10 weeks, the result would be a chat demo that shows none of Rui's strengths. Cheaper "try it in the browser" demo stays the scripted home-page one from the in-browser study.
- **iOS app / Shortcuts step**: Shortcuts already has a "Use Model" action (on-device, PCC, ChatGPT) on iPhone 15 Pro and later ([Apple support](https://support.apple.com/guide/shortcuts/tpg3vrvwmclv)), so a plain model step adds nothing. App Intents get about 30 s unless `LongRunningIntent` (iOS 27) is used ([Apple](https://developer.apple.com/documentation/appintents/longrunningintent)); extension memory caps are per extension type, 30-120 MB in forum reports (unverified). iOS forbids launching subprocesses, so Rui on iOS is a Zig library with client-run tools (Shortcuts actions, files) instead of Bash: a new platform. Worth revisiting after the Mac Apple spike, since the same model adapter would serve it.
- **Android AICore**: the ML Kit Prompt API runs Gemini Nano on a short device list (best on Pixel 10) ([Google](https://developers.google.com/ml-kit/genai)); Android needs bionic and a Kotlin host. Same shape as iOS, smaller payoff.
- **Windows native**: WSL works today; Phi Silica needs packaged apps on Copilot+ PCs. Revisit only if Windows users ask.
- **Watches, routers, embedded**: watchOS 27 can call PCC, but no shell; most routers are ARMv7/MIPS (device study). No use case found where tiny memory is the deciding factor.
- **Cloud functions**: covered by the stateless-servers study; not a friction reducer for a new user.
- **In-page models (WebLLM)**: WebGPU is on in Safari 26 and Chrome; small models (Qwen3 0.6B, ~335 MB) are weak at multi-step tool use (not measured); same browser-port cost.

## Confidence

- Read in primary sources today: every linked fact above.
- Read in Rui source: transport, codec, stateless request, provider list, instruction sizes.
- Guesses: every dev-cost size; whether PCC works for a non-App-Store CLI; Chat Completions need for GitHub Models; Copilot Free via `vscode.lm`; small-model tool quality.

## Proposed next steps

1. Apple spike (2-3 days, on Divyansh's Mac since it needs macOS 26/27 with Apple Intelligence): call `foundation-models-c` from a tiny Zig program; try on-device and PCC, one tool call, and measure Rui's instruction + tools token count against 8K/32K. Decide build or drop from the result.
2. If #1862 lands, add HTTP/1.1 loopback transport and an Ollama connection as the first non-OpenAI-host connection.
3. GitHub Action: confirm the GitHub Models wire format, then a Chat Completions codec and a small action wrapper.
4. Linux arm64 release when CI budget allows.
