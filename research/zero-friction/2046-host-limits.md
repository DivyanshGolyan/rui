# #2046 Hosts whose memory or time limits only a light harness fits

2026-11-23 · research only, nothing built or measured. Each claim is marked **[doc]** (vendor's own page, quoted), **[forum]** (vendor forum or third party), **[repo]** (read in Rui's source or docs at /home/user/rui), or **[guess]** (my inference).

## Answer

The hosts where a heavy harness truly cannot fit are the **phone ones**: iOS gives App Intents 30 seconds unless they adopt `LongRunningIntent` (iOS 27), app extensions get "significantly lower" memory (30 MB reported for intent extensions), and iOS has no Node and no subprocesses, so pi and Codex have no way in. Serverless is **not** a light-only niche any more: Cloudflare already runs pi and OpenCode inside a 128 MB Durable Object with crash recovery that does not re-run unsafe tools, and Vercel does the same for pi, Codex and Claude Code. AWS Lambda is the cheapest place for Rui to show up (its Linux binary and MySQL Store already fit), but the visible win there is cost and density, not "only Rui can do this".

## Ranked table

Ranking = user-visible difference ÷ porting cost. Both columns are **[guess]** except where a limit is quoted.

| # | Host | Hard limit (source) | Rui fits? | Port needed | User-visible win | Rank reason |
|---|---|---|---|---|---|---|
| 1 | **AWS Lambda** (custom runtime) | 128–10,240 MB memory; timeout 1,800 s (30 min); `/tmp` 512 MB–10 GB; 1,024 fds and 1,024 processes/threads [doc] | Yes, at the 128 MB floor [guess from the 2.5 MB/100 agents figure]. Codex app-server (≈206 MB) needs ≥256 MB; pi (≈112 MB) is at the edge of 128 MB [guess] | Small, ~1–2 weeks [guess]: a `bootstrap` that runs the Linux x86-64/arm64 build (both cross targets exist [repo]), Store on MySQL over TLS instead of `/tmp` SQLite (MySQL Store with ownership fence exists [repo]), a Runtime-API loop that turns an invocation into a Message | One event = one agent turn at the minimum price tier, and a turn cut by the 30-min cap or a freeze resumes on the next invocation from MySQL without re-running an uncertain tool | Low cost, modest but measurable win (memory tier is the bill) |
| 2 | **iOS app + App Intents / Shortcuts** | "it only has 30 seconds to finish" from Siri, Shortcuts or any system surface; `LongRunningIntent` (iOS 27) extends it while progress is reported, with a system Live Activity and stop button [doc]. No maximum stated [doc, absent] | Yes in the app process; probably yes in an extension [guess] | Large, ~6–10 weeks [guess]: `aarch64-ios` target, no fork/exec (Bash off; tools come from the app), sockets path checked against iOS networking rules, SQLite in the app container, Swift wrapper exposing intents | A Shortcuts step "ask my agent to do X" that runs on the phone with no server, outlives the 30 s budget, and resumes the same run after iOS kills it. No heavier harness runs on iOS at all [guess: no Node, no JIT for third parties] | Largest win; nobody else is there; high cost |
| 3 | **iOS app extensions** (Share, widget, intent extension) | "Memory limits for running app extensions are significantly lower than … a foreground app"; launch "well under one second" or be terminated; no background modes [doc, archive guide]. SiriKit intent extensions: 30 MB (Apple engineer, 2020) [forum]; widget 30 MB EXC_RESOURCE report [forum] | Plausibly [guess] | Same as #2 plus a minimal extension entry that hands work to the shared Store | Share a page to an agent from any app; the agent state survives the extension being killed | Rides on #2's port |
| 4 | **Android** foreground service / WorkManager | `dataSync`/`mediaProcessing` FGS: 6 h per 24 h (Android 15+); `shortService` ≈3 min; WorkManager workers past 10 min only as foreground workers [doc] | Yes [guess] | Medium, ~4–6 weeks [guess]: `aarch64-linux-android` (Rui's Linux code is close), JNI/Kotlin shell, Play policy for FGS type | Background agent on the phone for hours; restarts after the 6 h cut resume | No hard memory cap, so lightness matters less; pi can run under Termux [guess] |
| 5 | **Cloudflare Durable Objects / Workers** | 128 MB per isolate; CPU 30 s default, 5 min max per request (paid); no wall-clock limit while connected; alarms 15 min; 10 GB SQLite per DO; 6 connections waiting for headers [doc] | Only as Wasm [guess] | Large, ~8–12 weeks [guess]: wasm32 core, `fetch` instead of own TLS/HTTP/2 (`connect()` exists but 443 must use `fetch` [doc]), Store adapter on the DO SQL API, no Bash | Many agents per DO instead of one; already a design probe in ARCHITECTURE.md [repo] | Win shrank: Cloudflare runs **pi, Flue, OpenCode in the DO isolate** with eviction recovery and "Any other tool was running → Pi does not run it again" [doc]; Codex and Claude Code run in a container driven by a DO [doc] |
| 6 | **Chrome extension** service worker / offscreen doc | SW stops after 30 s idle, a request over 5 min, or a fetch over 30 s; WebSockets keep it alive (Chrome 116) [doc]. One offscreen doc at a time; only `runtime` API; no lifetime limit except audio [doc]. No memory limit documented | Only as Wasm | Large (prior study: 6–10 weeks) | An agent in the browser that survives worker termination | No memory cap, pi's JS runs there unchanged, ChatGPT plan unusable (prior study) |
| 7 | **watchOS** | App Intents 30 s [doc]; extended runtime sessions only for self care 10 min, mindfulness 1 h, physical therapy 1 h, smart alarm 30 min, chosen "based on the app's intended use" [doc] | Probably [guess] | Large | Little: no legitimate session type for an agent | Lowest |
| — | Vercel Functions | 2 GB (Hobby) / 4 GB (Pro); 300 s default, 800 s max, 1,800 s beta [doc] | Yes | — | None light-only: Vercel's `durable-harness` already resumes pi, OpenCode, Codex, Claude Code across timeouts [doc] | Not a niche |
| — | Supabase Edge Functions | 256 MB; 2 s CPU; 150 s free / 400 s paid wall clock [doc] | Only as Wasm | Like #5 | Small | Deno/JS host; pi fits [guess] |

## Per host detail

### AWS Lambda
- Limits [doc, docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html]: "Function memory allocation 128 MB to 10,240 MB"; "Function timeout 1,800 seconds (30 minutes)"; "/tmp directory storage between 512 MB and 10,240 MB"; "Execution processes/threads 1,024"; "File descriptors 1,024". CPU scales with memory ("At 1,769 MB, a function has the equivalent of one vCPU"). Lambda also offers durable functions (100 MB checkpoint storage per execution, 1 MB per operation) and MicroVMs (8 h).
- Fit: Rui's Host is a Linux process; Lambda allows processes and threads. Store on `/tmp` dies with the environment, so durability needs the MySQL Store, which already supports TCP + TLS with system trust and a `store_owner` ownership fence for a second Host [repo: docs/contracts/store.md, host.md]. That fence is exactly what concurrent Lambda environments need [guess].
- Tools: AWS SDK calls via MCP servers, web_search, sub-agents; Bash can run (Amazon Linux has a shell) but writes are ephemeral.
- Win: a queue or webhook drives an agent per event at the 128 MB price; a model call frozen or cut at 30 min resumes from MySQL. Heavier harnesses need larger tiers and, outside Vercel, their own durability.
- Unverified: real Rui RSS at cold start on Lambda; whether the Host's Unix socket and resolver threads behave under Lambda freeze/thaw.

### iOS App Intents and LongRunningIntent
- [doc developer.apple.com/documentation/appintents/longrunningintent] "In iOS, iPadOS, tvOS, visionOS, and watchOS, the system gives tasks 30 seconds to run in the background unless you use the methods of this protocol"; "If you don't update this property regularly, the system can cancel the background runtime extension". Available iOS 27.0+.
- [doc WWDC26 session 345] "When your intent runs, from Siri, Shortcuts, or any system surface, it only has 30 seconds to finish"; progress shows "automatically as a Live Activity" with a stop button; `CancellableIntent` gives a reason (timeout, user, resource reclaim) and a cleanup handler. The demo starts the intent from a widget button; whether a Shortcuts run keeps going in the background is not stated.
- [forum, Apple Frameworks Engineer, thread 832257] "App intents generally have 30 seconds to run on most Apple platforms (macOS has no fixed time limit)"; pair LongRunningIntent with CancellableIntent "to flush partial state, mark the sync resumable".
- iOS 26 also has `BGContinuedProcessingTask`: "starts in the foreground and can continue running in the background"; "The system can terminate a continuous background task abruptly … under resource constraints" [doc].
- Fit: Rui's whole design (every step saved, resume, no re-run of an uncertain call) matches "can be cancelled at any time, report progress, resume next run". Progress maps to Turn/Action events [guess].
- Port: no `fork`/`exec`, so tools are the app's own intents, MCP over network, web_search, sub-agents. TLS trust already has an Apple SecTrust path on macOS [repo: host.md transport]. SQLite is available. The map notes Apple's on-device/Private Cloud Compute model as a no-sign-in source.
- Win: "Summarise my unread mail and file the receipts" as one Shortcuts step that keeps running with a Live Activity and, if killed, continues without filing twice.

### iOS app extensions
- [doc ExtensibilityPG archive] "Memory limits for running app extensions are significantly lower than the memory limits imposed on a foreground app … the system may aggressively terminate extensions"; aim to launch "well under one second"; `UIBackgroundModes` in an extension is rejected; only background `NSURLSession` transfers continue after the extension ends.
- [forum 655189, Apple Frameworks Engineer, Jul 2020] "SiriKit Intents Extensions have a 30MB memory limit"; in-app intent handling "can use much more resources".
- `com.apple.developer.kernel.increased-memory-limit` raises the app's limit on some devices only [doc]; it says nothing about extensions.

### Android
- [doc developer.android.com fgs/timeout] "The system permits dataSync and mediaProcessing foreground services to run for a total of 6 hours in a 24-hour period"; the service then "has a few seconds to call Service.stopSelf()". `shortService`: "about 3 minutes" [doc service-types]. Long-running WorkManager workers "can run longer than 10 minutes" only via a foreground service [doc, via search snippet].
- No per-app hard memory cap for native code is documented; lightness helps against low-memory kills [guess].

### Cloudflare Workers and Durable Objects
- [doc workers/platform/limits] "Each isolate can consume up to 128 MB of memory"; CPU 30 s default, up to 5 min paid; HTTP wall clock "No hard limit while the client remains connected"; DO alarms 15 min; "up to six connections simultaneously waiting for response headers"; script 64 MiB.
- [doc durable-objects/platform/limits] SQLite storage 10 GB per DO; statement 100 KB; row 8 MB.
- [doc tcp-sockets] `connect()` exists with TLS, but "For HTTP on ports 80 or 443, use fetch"; an open socket keeps the DO in memory.
- [doc agents/harnesses] Pi, Flue, OpenCode, Think run in the DO isolate; Claude Code and Codex in "a Linux container, driven by a Durable Object"; Nanocode is "Wasm in its own Durable Object host". Containers' smallest instance is 256 MiB / 1/16 vCPU [doc].
- [doc agents/harnesses/pi] after eviction "the job's alarm restarts the object"; interrupted non-replay-safe tools are not re-run; restart limit 5; "Pi Durable is experimental".
- So the claim "only a light harness fits" holds for Codex/Claude Code, not for pi.

### Chrome extension
- [doc service-workers/lifecycle] terminated "After 30 seconds of inactivity", when a request "takes longer than 5 minutes", or "When a fetch() response takes more than 30 seconds to arrive"; WebSockets extend lifetime (Chrome 116).
- [doc offscreen API] "an installed extension can only have one open at a time"; "The runtime API is the only extensions API supported".
- [doc migrate/to-service-workers] Chrome does not support keeping a worker alive indefinitely in general; "prepare for unexpected termination".

### watchOS
- [doc WatchKit using-extended-runtime-sessions] table: Self care 10 min, Mindfulness 1 h, Physical therapy 1 h, Smart alarm 30 min; "Select a session type based on the app's intended use"; high CPU can end the session with `exceededResourceLimits`.

### Vercel and Supabase
- [doc vercel.com/docs/functions/limitations] memory 2 GB Hobby, 4 GB Pro; duration 300 s default, 800 s max, 1,800 s beta.
- [doc vercel.com/docs/agent-harnesses] "When a crash, a function timeout, or a redeploy stops a turn, a new function resumes it from the session's log"; interrupted non-safe tool calls "come back to the model as possibly run". Beta.
- [doc supabase.com/docs/guides/functions/limits] 256 MB, 2 s CPU, 150 s / 400 s wall clock.

## Unverified or open
- The iOS extension memory number is a 2020 forum answer about SiriKit extensions, not App Intents extensions; no current Apple figure found.
- `LongRunningIntent`: no documented maximum duration, and no statement that a Shortcuts-started run continues in the background.
- Whether Rui's own BSD-socket transport is acceptable on iOS (cellular, VPN on demand) was not checked.
- "No heavier harness can run on iOS" is inferred (no Node; Codex's Rust core was not checked for an iOS build).
- Rui's memory on any of these hosts is not measured; the 2.5 MB/100 agents figure is the caller's.
- Porting estimates are guesses from reading the layout, not from compiling.
- Android WorkManager 10-minute figure came from a search snippet of the official page, not a full read.
