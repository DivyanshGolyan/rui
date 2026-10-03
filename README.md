# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. It keeps reusable conversations working after clients disconnect and recovers durable work after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

Rui is in development. Today the direct CLI can configure reusable Sessions, queue messages, receive text-model responses, stop or interrupt work, inspect proposed tools, authorize Bash and read saved results. Bare `rui` starts a new Session; `rui --resume [REF]` starts or attaches the Host and enters an existing one. All new commands select a Store by explicit `--store`, then saved preference, then the HOME fallback; one-shot commands stay nonblocking and scriptable, and scripts can pin `--store` for deterministic targeting. `rui host start [--store PATH]` launches a detached capacity-8 managed Host or attaches to the existing owner without changing its settings; readiness does not require credentials. `rui host status [--store PATH]` reads protected readiness, actual capacity and capabilities without starting a Host; unavailable or owned-but-unavailable does not prove cleanup. `rui setup` reports prospective provider/model selection, local credential state and separate Host capability without creating a Session or starting a Host. The Host is not installed as an OS service and has no automatic restart. Mutations save generated keys before transmission; the explicit-key/record commands remain available. Keyed requests, permission decisions and admitted work survive restart.

`rui sessions [--store PATH] [--all] [--json]` lists Host-owned configured Sessions, including those absent from local request records, in bounded pages. By default it filters exact canonical cwd; `--all` spans Workspaces. JSON emits one complete page per line. It observes only and does not select a Session for resume. `rui --resume [REF] [--store PATH]` starts or attaches to that Store's Host, selects an existing Session by exact reference or a bounded current-Workspace picker (with an all-Workspaces option), and enters without reconfiguring or submitting. `/resume [REF]` switches from within a Session; `/history` traverses older fixed-end public pages. Missing credentials do not change an existing binding or prevent inspection; use `/login` for optional repair.

The Host exposes a [bounded public Session view](ARCHITECTURE.md#public-session-view) for interactive opening/catch-up and independent [public Conversation pages](ARCHITECTURE.md#public-conversation-pages) for `/history`. Opening shows a recent 16-item Session page chronologically; historical content beyond 8 KiB is visibly omitted with exact length and identity, while live catch-up is complete. `rui conversation-content [--store PATH] --session REF --position N --ordinal N --output FILE` streams the complete raw public item to a new private file in bounded windows (failed transfer may leave an incomplete file). Private provider reasoning is excluded. Public Message and call-content reads remain independent; exact Action inspection remains the separate approval authority.

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

Persistent Session-view positions change the unreleased Store schema to version 19. Older development Stores are not migrated or deleted; use a newly configured Store with this build. Installing the executable alone does not touch an existing Host or Store.

For ordinary terminal use, build Rui, then run it from the project you want Bash to use as its Workspace:

```sh
RUI="$(realpath zig-out/bin/rui)"  # run this from the Rui checkout after zig build
cd /path/to/project
"$RUI"                  # new Session; attaches to or starts the background Host
"$RUI" --resume         # later, choose a Session in this Workspace
"$RUI" --resume my/ref  # or re-enter one exact saved reference
"$RUI" host status      # inspect the selected Store without starting it
```

The first run asks for a supported locally ready provider; Codex login can be started or deferred. Deferring without a ready provider creates no Session. Rui prints each new Session reference and keeps its saved configuration handle in `rui requests` for exact recovery after an uncertain reply. A bare invocation is **always new intent**, not a guess at the last Session; existing Sessions keep their bound model and permissions. `/help`, `/status` and `/history` are available inside a Session. `rui host stop` requests shutdown for **every** Session in that Store; do not use it merely to detach. Scripts should use explicit one-shot commands with `--store` and `--session` instead of the terminal entry point.

The production default Active Capacity remains 1,000. Startup rejects a requested population when the process descriptor limit cannot support it, so this development command selects a smaller population that fits ordinary finite limits. Model transport is disabled by default. Development testing requires an explicit `--provider-endpoint`: HTTPS (negotiated HTTP/2 required) or loopback HTTP/1.1, with no authentication attached. A private test CA can be selected with `--provider-ca-file PATH`; peer and hostname verification remain enabled. Run `./zig-out/bin/rui --help` to print command usage without starting a Session or Host.

On macOS, Host startup applies [memory-efficient allocator defaults](ARCHITECTURE.md#resident-memory-invariant). Prefix `rui serve` with `RUI_HOST_MALLOC_DEFAULTS=0` to disable Rui's defaults; explicit Apple allocator environment values remain untouched. Linux startup is unchanged.

For a private default Store, `./zig-out/bin/rui host start` starts a managed background Host using saved Store preferences or `$HOME/.local/share/rui/store`; use `--store PATH` to select an explicit Store. The caller waits up to ten seconds for protected readiness and prints its `diagnostics/` location. Startup records are private and bounded (128 MiB, at most 16 files); a startup failure before lease acquisition may leave no record. On timeout or a disconnected caller, inspect `rui host status` and those records if present rather than assuming the Host was stopped or repeating a mutation. Existing ready Hosts retain their original capacity and capabilities. `rui host stop [--store PATH]` discovers and targets one observed instance even when ordinary readers fill their ten places, and affects **all** work in that Store. Discovery is bounded and shares control headroom, not an unlimited flood-proof channel. It prints the target before sending; if its reply is lost, retain the same Store and use `--instance HEX` to retry without stopping a replacement. Acknowledgement means shutdown was requested, not that cleanup and lease release finished. `zig build host-launch-integration` and `host-stop-integration` have run natively on Linux x86-64 and macOS arm64, including mixed-effect shutdown and held cleanup; each revision's evidence is recorded in [verification](VERIFICATION.md#server-ownership-and-connection-capacity), and neither proves power-loss recovery.

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
"$RUI" --resume my/codex --store "$STORE"
```

The example uses the **new** Session defaults: Bash only and `bypass`, so Bash can run without a permission prompt. Existing Sessions keep their saved settings; `/status` shows them. Use `--permission-mode ask` at configuration (or `/configure --permission-mode ask` while entered) when you want to approve each proposed Action.

The interactive caller consumes one [Host-derived Session view](ARCHITECTURE.md#public-session-view): pending admissions, applied Messages, assistant text, public calls, complete Tool Results, stops and retained outcomes. Calls describe saved proposals, not proof of execution. Private reasoning is excluded; shared public reads and exact Action inspection remain available independently. Historical Conversation content above 8 KiB is explicitly omitted with exact length and an export command; proposal names/arguments remain complete on replay. Live catch-up streams complete content, including work committed during opening and later Turns. Only assistant text receives terminal-safe Markdown; user/tool bytes are escaped. This replaces optional call narration and automatic selected-Message following.

Compose at the `> ` prompt, with indented continuation lines, while Session facts append to ordinary scrollback. Host-confirmed input is labelled `You:`; each assistant answer retains its horizontal divider and Markdown. Internal IDs, pagination metadata, zero counters and redundant completion receipts are absent from ordinary conversation. The footer is silent when idle and shows only work, nonzero queued input or attention/recovery instructions. The opening header shows exact Session, Workspace, provider/model and permission mode, warning once for Bash bypass; automatic Host start/attachment is silent. Accepted text is not permanently echoed then repeated on application. Failed outcomes remain distinct from later answers. Submission saves an immutable recovery capture and holds the submitted draft while you compose the next Message; only one admission can remain unresolved, and its reply never clears new composition. A lost reply requires Ctrl-R to recover the same identity while preserving composition, not another send; `/recover` is also available from an empty command line. Definite rejection restores the original when the new draft is empty; otherwise `/discard` explicitly releases the rejected original, never uncertain admission. Terminal and admission custody survive `/resume`, with capture bound to its original Session.

Ctrl-G explicitly inspects an Action while preserving the draft; attention never steals focus. `/approve` is available from an empty command line. Exact inspection precedes a fresh allow-once/deny/later choice and Host revalidation. `/help`, `/status`, `/history`, `/requests`, `/result KEY` and explicit `/wait` remain available; `/wait` selects work once rather than retargeting later activity. `/configure --model MODEL` changes this Session, while `/setup` and `/login` affect prospective preferences/credentials, not its binding. File-valued interactive options require a path rather than `-`. `/exit` or Ctrl+C detaches without stopping Host work. Unknown Sessions require configuration and interactive entry requires a TTY; one-shot commands remain scripted. `rui result KEY` and JSON preserve original answer bytes and keyed recovery remains available from fresh callers.

Enter seals the submitted bytes before later typeahead can edit the next draft. Host reads and terminal output can be held without preventing input service or typed detachment; a parser/output failure restores terminal custody before scoped helpers are joined. Physical terminal input closure is an invocation failure, not a successful receipt for a partially displayed answer. Approval escape-sequence timeouts apply during inspection and prompt delivery too. Native blocked-device/Darwin output-drain cancellation remains unqualified; Linux PTY probes are not a guarantee for arbitrary terminal drivers.

The editor supports arrows, Home/End, Backspace/Delete, Ctrl-A/E/U/K/W/D and ESC-Backspace, with Unicode cell-aware wrapping and multiline layout in at most six footer rows. Bracketed paste can contain newlines as one Message; ordinary Enter sends. Exactly 65,536 UTF-8 bytes fit each draft bank; overlong/invalid attempts reject in full even after deletion. Use one-shot `message --text FILE` for larger input. Resize preserves exact draft/cursor/capture and reanchors with a notice; old prompt/indented fragments may remain, without history erase/replay. Arbitrary external terminal writes are not supported. There is no message history or completion. Physical Option/Command shortcuts depend on received terminal sequences. Approval drains output and flushes typeahead before a separate parser accepts exact `a`, `d` or `l` plus Enter, never marked paste; unmarked input arriving afterward cannot be distinguished from typing. Output/restoration failures are fatal.

For one-shot/scripted use, omit both `--record` and `--key` from `configure`, `message`, `allow-action` or `deny-action`. Each prints a saved request handle before sending, then an admission and destination/next step; a human receipt points to `rui --resume REF` for conversation, while scripts can still use the saved handle with `follow` or `result` to observe precisely that Message. `--json` gives deterministic newline-delimited capture and admission objects. Pin `--store` for deterministic scripts and supply the full Session reference on each new mutation:

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

`message` accepts literal positional text, `-` for stdin, or `--text FILE` to capture a file. `wait-session` selects work once and returns idle immediately if none; `--terminal` waits past permission attention for the selected terminal outcome. `follow HANDLE` always stays bound to that saved Message and can show an earlier Turn's permission while its Message is queued. `requests` only lists local records; `recover` reuses the exact saved inputs after an uncertain reply, even if the input file changes. The private records live under `~/.config/rui/requests` and do not expire independently. A new message needs a new command/key. Result and inspection rendering use unlinked temporary scratch under `TMPDIR` (or `/tmp`), not durable request records. Explicit `--record` and `--key` retain the original low-level JSON route.

`rui setup` inspects private Store/provider/model choices without changing them. `--provider codex` saves a provider choice; `--model MODEL` pins any locally valid identifier (1–256 printable non-space ASCII bytes), and `--clear-model` restores recommendation inheritance. These model flags are mutually exclusive; empty `--model` is invalid. Same-provider and Store-only edits keep an explicit pin; a provider change clears the prior model unless replaced. Model-only setup uses the saved or sole locally usable provider. The adapter recommends `gpt-6-luna`; local identifier validity is not qualification or account entitlement, and only the previously documented exact model/platform journey is qualified. Setup reports ready credentials needing renewal separately from pending/uncertain refresh, without refreshing, networking or creating credential locks. Expired valid ready credentials remain usable for new-Session selection; runtime renews at dispatch. A saved preference never silently falls back. Saving provider/model or logging in does not depend on an unused saved Store's availability; setup reports Store/Host availability separately. A supplied Store replacement must be an existing private directory and is saved canonically. `/setup` changes only future defaults; quote values containing spaces (for example `/setup --store "/path/to/my store"`), escaping embedded `"` or `\` as needed. `/configure` uses the same quoting without shell expansion.

`rui --resume REF` selects the explicit, saved or HOME Store and starts or attaches its Host. A selected missing saved Store fails without recreation; valid absent explicit/HOME destinations remain creatable. Bare `rui` checks the selected destination and existing Host's model capability before offering credential repair, repeats needed selection/checks after the prompt, then creates a distinct Session in canonical cwd with Bash and `bypass`. All three explicit selectors skip preference reading, even after login; consulting preferences still rejects malformed or unsafe files. An unused missing saved Store cannot block an explicit valid destination with inherited provider/model. The header warns that Bash runs without approval. Rui prints the Session reference and saved configuration handle; `rui recover HANDLE` reuses that exact key/reference/model after defaults change or a reply is lost, while a second bare invocation is new intent. `rui --store PATH --provider codex --model gpt-6-luna` overrides future defaults for that invocation. Non-TTY bare invocation rejects before mutation; one-shot commands stay prompt-free and retain their explicit keys and Session targets. Workflow Session discovery waits for the Host Workflow inspection operation. The [Bash walkthrough](#try-the-implemented-development-path) still demonstrates the explicit-key route with a deterministic endpoint.

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
