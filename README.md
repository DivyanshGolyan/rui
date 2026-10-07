# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. It keeps reusable conversations working after clients disconnect and recovers durable work after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

Rui is in development. Today the direct CLI can configure reusable Sessions, queue messages, receive text-model responses, stop or interrupt work, inspect proposed tools, authorize Bash and read saved results. `rui session` is a terminal caller for an already configured Session. All new commands select a Store by explicit `--store`, then saved preference, then the HOME fallback; one-shot commands stay nonblocking and scriptable, and scripts can pin `--store` for deterministic targeting. `rui host start [--store PATH]` launches a detached capacity-8 managed Host or attaches to the existing owner without changing its settings; readiness does not require credentials. `rui host status [--store PATH]` reads protected readiness, actual capacity and capabilities without starting a Host; unavailable or owned-but-unavailable does not prove cleanup. `rui setup` reports prospective provider/model selection, local credential state and separate Host capability without creating a Session or starting a Host. The Host is not installed as an OS service and has no automatic restart. Mutations save generated keys before transmission; the explicit-key/record commands remain available. Keyed requests, permission decisions and admitted work survive restart.

`rui sessions [--store PATH] [--all] [--json]` lists Host-owned configured Sessions, including those absent from local request records, in bounded pages. By default it filters exact canonical cwd; `--all` spans Workspaces. JSON emits one complete page per line. It observes only and does not select a Session for resume.

The Host also exposes [bounded public Conversation pages](ARCHITECTURE.md#public-conversation-pages) and byte-range content continuation for a later resume caller. This is a Host wire API only; the current CLI does not yet render or browse those pages.

The precise model is documented in [Architecture](ARCHITECTURE.md): valid Bash descriptors become inspectable Actions, unknown tools and invalid descriptors become stable call-local rejections, and a Bash attempt that loses local custody resolves as indeterminate rather than replaying automatically.

JavaScript workflows, Edit and structured answers are not implemented. Rui now packages a pinned QuickJS child and a private evaluator lifecycle owner with compile-only validation of a direct default-exported async function and capability-only entry invocation, checked by `zig build workflow-check` and `zig build evaluator-host-integration`. Its read-only prepared-input descriptor is reserved for later saved-result lookup; this slice does not decode those results. No production Host path invokes it yet: Workflow creation/admission and Session-call bindings are follow-on slices, and full cross-platform evaluator qualification remains outstanding. Rui-owned Codex login, private credentials and managed transport have deterministic/native fixture coverage. The exact `gpt-6-luna` subscription journey passed natively on Linux x86-64 and macOS arm64: private reasoning replayed within one Session, exact approved Bash, continuation, fresh-Host recovery and a new live request over HTTP/2. The same-Session replay is the accepted [#272 proof](VERIFICATION.md#context-provider-output-and-compaction); a reasoning item in the Bash proposal itself is not required. Disposable instrumented runs also recorded [native TLS allocator requests](tests/qualification/issue-272/README.md) on both platforms. Live refresh, other models/platform pairs, Bash detached-descendant containment, power-loss and complete 1,000-operation mixed qualification remain outstanding. Retained full output is optional: FIFO eviction or restart may remove it without changing the saved result.

Targets Linux and macOS on x86-64 and ARM64. All four cross-compile. Broad runtime/resource qualification has run on Apple Silicon macOS. The model-queue workload has run on Linux and macOS; its macOS run passed the required physical-footprint target.

## Build

Requires Zig 0.16.0, Python 3, Perl, `patch`, a C toolchain and Make. The build pins native dependencies.

```sh
zig build
zig build test-logic
zig build check
./zig-out/bin/rui serve \
  --store /absolute/path/to/private-store \
  --active-capacity 8
```

Use focused tests while editing and `check` at integration checkpoints and before merge. It runs native and process suites concurrently, then isolates short-deadline Host-startup and Debug artifact/recovery smoke cases. `check-full` adds the evaluator string sanitizer and runs suites serially for build/dependency changes and isolated full-suite evidence. Both retain the full ReleaseSafe admission matrix and native tests, ReleaseSafe and Debug Host builds, and a ReleaseSmall production build. The complete Debug matrix (`admission-debug-integration`), real-time 61-second deadline witness (`test-full`) and 1,000-evaluation reuse witness (`evaluator-churn`) run separately for affected changes and release qualification; routine gates keep short deadline and ten-cycle reuse checks. See [canonical gates](VERIFICATION.md#canonical-gates) for exact cadence and evidence limits.

The production default Active Capacity remains 1,000. Startup rejects a requested population when the process descriptor limit cannot support it, so this development command selects a smaller population that fits ordinary finite limits. Model transport is disabled by default. Development testing requires an explicit `--provider-endpoint`: HTTPS (negotiated HTTP/2 required) or loopback HTTP/1.1, with no authentication attached. A private test CA can be selected with `--provider-ca-file PATH`; peer and hostname verification remain enabled. Run `./zig-out/bin/rui --help` to print command usage without starting a Session.

On macOS, Host startup applies [memory-efficient allocator defaults](ARCHITECTURE.md#resident-memory-invariant). Prefix `rui serve` with `RUI_HOST_MALLOC_DEFAULTS=0` to disable Rui's defaults; explicit Apple allocator environment values remain untouched. Linux startup is unchanged.

For a private default Store, `./zig-out/bin/rui host start` starts a managed background Host using saved Store preferences or `$HOME/.local/share/rui/store`; use `--store PATH` to select an explicit Store. The caller waits up to ten seconds for protected readiness and prints its `diagnostics/` location. Startup records are private and bounded (128 MiB, at most 16 files); a startup failure before lease acquisition may leave no record. On timeout or a disconnected caller, inspect `rui host status` and those records if present rather than assuming the Host was stopped or repeating a mutation. Existing ready Hosts retain their original capacity and capabilities. `rui host stop [--store PATH]` targets one observed instance and affects **all** work in that Store. It prints the target before sending; if its reply is lost, retain the same Store and use `--instance HEX` to retry without stopping a replacement. Acknowledgement means shutdown was requested, not that cleanup and lease release finished. `zig build host-launch-integration` and `host-stop-integration` have run natively on Linux x86-64 and macOS arm64, including mixed-effect shutdown and held cleanup; the [complete platform-specific launch acceptance matrix](VERIFICATION.md#server-ownership-and-connection-capacity) remains outstanding.

For the qualified exact `gpt-6-luna` binding, sign in once with Rui and start a managed Host against a private Store:

```sh
RUI="$PWD/zig-out/bin/rui"
STORE="$HOME/.local/share/rui/store"
"$RUI" login codex
"$RUI" serve --store "$STORE" --active-capacity 8 --codex
```

In another terminal, configure a Session whose Workspace is the **actual project directory** (Bash uses it as its working directory), and enter it:

```sh
RUI="$PWD/zig-out/bin/rui"
STORE="$HOME/.local/share/rui/store"
"$RUI" configure --store "$STORE" --session my/codex --workspace "$PWD" \
  --provider codex --model gpt-6-luna
"$RUI" session --store "$STORE" --session my/codex
```

The example uses the **new** Session defaults: Bash only and `bypass`, so Bash can run without a permission prompt. Existing Sessions keep their saved settings; `/status` shows them. Use `--permission-mode ask` at configuration (or `/configure --permission-mode ask` while entered) when you want to approve each proposed Action.

At `rui>`, type a message. The opening header shows the exact Session, Workspace, provider/model and permission mode, warning when Bash bypasses approval. It saves the request and waits for its answer. Interactive output labels You, Assistant and Rui without relying on color; successful answers omit request receipts and completion labels. While waiting, Rui reports observed queue/work status and occasional still-in-flight reminders without inventing tool activity; a failed saved Message remains distinct from a later answer. `/help` lists the implemented Session commands; `/requests` retains local recovery handles and `/status` shows Store, effective settings, current work and recent message keys (terminal controls escaped). `/setup` inspects future defaults without authentication; `/login` offers Codex device login or deferral with a fresh choice. A successful login saves Rui-owned credentials and fills Codex/gpt-6-luna for future Sessions only when no provider default exists; credential installation and preference saving have independent outcomes. Login does not verify remote model acceptance or rebind this Session. In `ask` mode, Rui displays the exact Action ID and complete arguments (control characters escaped) before offering **allow once**, **deny** or **later**. The opaque call ID remains available with one-shot `inspect-action`. `/result KEY` reads a prior answer even from a fresh caller without local records. On re-entry, `/wait` follows the active Turn (or oldest queued admission) once; `/configure --model MODEL` updates this Session (file-valued options need a path, not `-`); `/exit` or Ctrl+C at a prompt detaches without stopping Host work. Interactive lines beyond 64 KiB are rejected without sending; use one-shot `message --text FILE` for longer text. Unknown Sessions must be configured before entry. `rui session` requires a terminal; it does not silently become a scripted mode on redirection. If a submission or decision loses its reply, use `rui requests` and `rui recover HANDLE` rather than creating a new request by guessing what happened. A confirmed admission whose later observation fails remains accepted; inspect its original saved key rather than resubmitting.

The inline prompt supports arrows, Home/End, Backspace/Delete, Ctrl-A/E/U/K/W/D and ESC-Backspace for word deletion. Terminal-marked (bracketed) paste can include newlines as one Message; ordinary Enter sends. There is no message history or completion. Option-Backspace works when your terminal sends ESC-Backspace. Command-Backspace clears to the line start only if your terminal is configured to send Ctrl-U; Ghostty's default legacy encoding sends the same DEL byte as ordinary Backspace, so Rui cannot distinguish them. An overlong or invalid draft is rejected in full, even if you later delete characters. If the terminal cannot safely position the cursor for an edit (for example near a wrap), no Message is sent; use the one-shot `message --text FILE` route. An Action prompt accepts only a fresh `a`, `d` or `l` and Enter, never a marked paste; unmarked paste *after* that prompt cannot be distinguished from typing.

For one-shot/scripted use, omit both `--record` and `--key` from `configure`, `message`, `allow-action` or `deny-action`. Each prints a saved request handle before sending, then an admission and destination/next step; a human receipt points to `rui session` for conversation, while scripts can still use the saved handle with `follow` or `result` to observe precisely that Message. `--json` gives deterministic newline-delimited capture and admission objects. Pin `--store` for deterministic scripts and supply the full Session reference on each new mutation:

```sh
./zig-out/bin/rui configure --store /absolute/path/to/private-store --session my/codex \
  --workspace /absolute/path/to/workspace --provider codex --model gpt-6-luna \
  --permission-mode ask
./zig-out/bin/rui message --store /absolute/path/to/private-store --session my/codex "Investigate the failing test"
./zig-out/bin/rui follow SAVED_MESSAGE_HANDLE
./zig-out/bin/rui wait-session --store /absolute/path/to/private-store --session my/codex
./zig-out/bin/rui inspect-action --store /absolute/path/to/private-store --session my/codex --action ACTION_ID
./zig-out/bin/rui allow-action --store /absolute/path/to/private-store --session my/codex --action ACTION_ID
./zig-out/bin/rui result SAVED_MESSAGE_HANDLE
./zig-out/bin/rui requests
./zig-out/bin/rui recover SAVED_MESSAGE_HANDLE
```

`message` accepts literal positional text, `-` for stdin, or `--text FILE` to capture a file. `wait-session` selects work once and returns idle immediately if none; `--terminal` waits past permission attention for the selected terminal outcome. `follow HANDLE` always stays bound to that saved Message and can show an earlier Turn's permission while its Message is queued. `requests` only lists local records; `recover` reuses the exact saved inputs after an uncertain reply, even if the input file changes. The private records live under `~/.config/rui/requests` and do not expire independently. A new message needs a new command/key. Result and inspection rendering use unlinked temporary scratch under `TMPDIR` (or `/tmp`), not durable request records. Explicit `--record`/`--key` mutations and `retry` render semantic JSON from the same validated Client result as human/generated JSON output, with original request context and typed failure diagnostics, not raw Host wire bytes. An invocation failure is nonzero and unconfirmed, never proof of rejection or noncommit. `rui setup` inspects the private Store/provider/model defaults without changing them, or saves them with `--store PATH --provider codex --model gpt-6-luna`. Only that qualified model is a supported managed setup default; other exact model strings remain available to explicit one-shot configuration. Without a saved choice, the sole locally configured supported provider is proposed; otherwise setup asks for a provider choice. Missing, expired/pending or unreadable Rui credentials are reported without refresh or network check; a saved preference never silently falls back. `/setup` works within an interactive Session but changes only future defaults; quote values containing spaces (for example `/setup --store "/path/to/my store"`), escaping embedded `"` or `\` as needed. The same quoting works for `/configure`; these commands do not perform shell expansion. `rui session --session REF` uses the saved Store or `$HOME/.local/share/rui/store` when `--store` is omitted. Store paths must already exist and pass the canonical/private checks; setup does not start a Host or configure a new Session. Bare `rui` on a TTY creates a distinct Session in canonical cwd with Bash and `ask`, after attaching to or starting a Host and selecting a locally ready supported provider. It prints the Session reference and saved configuration handle; `rui recover HANDLE` reuses that exact request after a lost reply, while a second bare invocation makes another Session. `rui --store PATH --provider codex --model gpt-6-luna` overrides future defaults for that invocation. Non-TTY bare invocation rejects before mutation; explicit one-shot commands remain unchanged. Workflow Session discovery waits for the Host Workflow inspection operation. The [Bash walkthrough](#try-the-implemented-development-path) still demonstrates the explicit-key route with a deterministic endpoint.

Managed mode uses `POST /backend-api/codex/responses` with verified TLS and negotiated HTTP/2; it does not attach credentials to a development endpoint. The device-code login requires account/workspace enablement and persists under `~/.config/rui/codex.json` for reuse across Host restarts. `RUI_CODEX_CREDENTIAL_FILE` may instead select another absolute path under an owner-only directory. Rui refreshes when required, but a failed or interrupted refresh may require a new login; live refresh was not exercised. Edit and output schemas fail before managed dispatch. The live responses reported `gpt-6-luna` in their bodies; served-model headers and provider correlation were absent, and direct ALPN observation was unavailable. This qualifies only the stated model, route and native platform pairs—not general Codex model availability or a release-wide resource bound.

`zig build codex-integration` exercises a synthetic credential, exact Bash approval, private continuation and fresh-Host recovery through public callers. `zig build codex-h2-integration` additionally needs Python `h2==4.3.0` and OpenSSL and checks managed TLS/HTTP2 negotiation, connection reuse and conditional FedRAMP routing. Neither uses live credentials.

`zig build codex-credential-integration` also tests cross-process credential mutation without live tokens. The opt-in `python3 tests/integration/codex_live.py /absolute/path/to/rui --live --model gpt-6-luna` runs the accepted public-caller journey with isolated disposable credentials and payload-free observations; it is not in ordinary build gates. For repeated authorized runs, `--credential-file /absolute/path/to/private/codex.json` reuses a Rui-owned credential instead of prompting for a fresh device login each time.

## Try the implemented development path

Run the narrated public-caller journey from issue [#260](https://github.com/DivyanshGolyan/rui/issues/260): configure an ask-mode Session, submit a message, inspect and approve one exact Bash Action, read its saved answer, crash the Host, then recover the original submission without repeating the effect.

```sh
zig build bash-walkthrough
```

The prerequisites are the same as [Build](#build). The walkthrough prints the actual `configure`, `message`, `inspect-session`, Action-read, `allow-action`, `read-result` and `retry` commands with their observations. It creates an explicit temporary Workspace and Store, starts only its own local Host and deterministic provider endpoint, and removes those owned resources on success. The Workspace is a working directory, not a sandbox. Acceptance is not completion, and approval authorizes only the inspected Action.

This development smoke check is not a live-provider quickstart or power-loss test. Its process crash occurs after the result and effect cleanup are committed; the fresh Host proves recovery of those saved facts without another Bash or provider effect. See the [acceptance audit and limits](VERIFICATION.md#runnable-bash-caller-acceptance-audit). Run `zig build bash-integration` for the full maintained Bash journey.

## Development direction

The [delivery plan](https://github.com/DivyanshGolyan/rui/issues/164) separates [direct-core development readiness](https://github.com/DivyanshGolyan/rui/issues/168) from [full qualification](https://github.com/DivyanshGolyan/rui/issues/231). Essential safety evidence stays with each capability; broad qualification does not block independent feature development after the readiness checkpoint. Full stage, support, performance and release claims still require their evidence.

The runnable #260 slice and native [Codex path](https://github.com/DivyanshGolyan/rui/issues/272) are described above. Local qualification evidence is complete for that exact-model slice; publishing changes and closing the issue are separate delivery actions. A [minimal durable workflow](https://github.com/DivyanshGolyan/rui/issues/273) remains planned; these links do not expand the implemented surface described in [Status](#status).

## Read next

- To explain ordinary work, recovery, ownership or resource policy, read [Architecture](ARCHITECTURE.md).
- To locate the source that owns a behavior, use the [implementation map](ARCHITECTURE.md#finding-the-implementation).
- To change Session behavior or verify an implementation slice, find the owning behavior in Architecture and its required evidence in [Verification](VERIFICATION.md).
- To run or interpret qualification, start with [current qualification](tests/qualification/README.md#current-checks-and-qualification); it records revision-specific observations and their limits.
- To inspect design evidence or archived experiments, read [Research](research/README.md).
- Contributors should follow [working rules](AGENTS.md). Dependencies and notices live in [third-party notices](THIRD_PARTY_NOTICES.md).
