# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. It keeps reusable conversations working after clients disconnect and recovers durable work after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

Rui is in development. Today the direct CLI can configure reusable Sessions, queue messages, receive text-model responses, stop or interrupt work, inspect proposed tools, authorize Bash and read saved results. One-shot human commands save generated-key requests before transmission; the explicit-key/record commands remain available. Keyed requests, permission decisions and admitted work survive restart.

The precise model is documented in [Architecture](ARCHITECTURE.md): valid Bash descriptors become inspectable Actions, unknown tools and invalid descriptors become stable call-local rejections, and a Bash attempt that loses local custody resolves as indeterminate rather than replaying automatically.

JavaScript workflows, Edit and structured answers are not implemented. Rui-owned Codex login, private credentials and managed transport have deterministic/native fixture coverage. The exact `gpt-6-luna` subscription journey passed natively on Linux x86-64 and macOS arm64: private reasoning replayed within one Session, exact approved Bash, continuation, fresh-Host recovery and a new live request over HTTP/2. The same-Session replay is the accepted [#272 proof](VERIFICATION.md#context-provider-output-and-compaction); a reasoning item in the Bash proposal itself is not required. Disposable instrumented runs also recorded [native TLS allocator requests](tests/qualification/issue-272/README.md) on both platforms. Live refresh, other models/platform pairs, Bash detached-descendant containment, power-loss and complete 1,000-operation mixed qualification remain outstanding. Retained full output is optional: FIFO eviction or restart may remove it without changing the saved result.

Targets Linux and macOS on x86-64 and ARM64. All four cross-compile. Broad runtime/resource qualification has run on Apple Silicon macOS. The model-queue workload has run on Linux and macOS; its macOS run passed the required physical-footprint target.

## Build

Requires Zig 0.16.0, Python 3, Perl, a C toolchain and Make. The build pins native dependencies.

```sh
zig build
zig build test-logic
zig build check
zig build check-full
./zig-out/bin/rui serve \
  --store /absolute/path/to/private-store \
  --active-capacity 8
```

`check` runs native and process suites concurrently for warm development feedback, then runs the short-deadline Host-startup and Debug admission cases without the parallel load; it skips one real-time 61-second client deadline witness. Run `check-full` before claiming full gate evidence: it includes that witness and runs process integrations serially so their latency observations are not perturbed by unrelated suites. Both use ReleaseSafe native tests, ReleaseSafe and Debug Host builds, and a ReleaseSmall production build; see [canonical gates](VERIFICATION.md#canonical-gates).

The production default Active Capacity remains 1,000. Startup rejects a requested population when the process descriptor limit cannot support it, so this development command selects a smaller population that fits ordinary finite limits. Model transport is disabled by default. Development testing requires an explicit `--provider-endpoint`: HTTPS (negotiated HTTP/2 required) or loopback HTTP/1.1, with no authentication attached. A private test CA can be selected with `--provider-ca-file PATH`; peer and hostname verification remain enabled. Run `./zig-out/bin/rui` to print command usage.

For the qualified exact `gpt-6-luna` binding, sign in once with Rui and start a managed Host against a private Store:

```sh
./zig-out/bin/rui login codex
./zig-out/bin/rui serve --store /absolute/path/to/private-store --active-capacity 8 --codex
```

In another terminal, configure a Session with a private Workspace and a fresh command key (choose paths you own):

```sh
./zig-out/bin/rui configure --store /absolute/path/to/private-store \
  --record /absolute/path/to/private-record/configure.json --key unique-configure-key \
  --session my/codex --workspace /absolute/path/to/workspace \
  --provider codex --model gpt-6-luna --tools bash --permission-mode ask
```

For one-shot use, omit both `--record` and `--key` from `configure`, `message`, `allow-action` or `deny-action`. Each prints a saved request handle before sending and then its admission. Start the Host separately; use the same explicit Store and full Session reference on each new mutation:

```sh
./zig-out/bin/rui configure --store /absolute/path/to/private-store --session my/codex \
  --workspace /absolute/path/to/workspace --provider codex --model gpt-6-luna \
  --tools bash --permission-mode ask
./zig-out/bin/rui message --store /absolute/path/to/private-store --session my/codex "Investigate the failing test"
./zig-out/bin/rui follow SAVED_MESSAGE_HANDLE
./zig-out/bin/rui inspect-action --store /absolute/path/to/private-store --session my/codex --action ACTION_ID
./zig-out/bin/rui allow-action --store /absolute/path/to/private-store --session my/codex --action ACTION_ID
./zig-out/bin/rui result SAVED_MESSAGE_HANDLE
./zig-out/bin/rui requests
./zig-out/bin/rui recover SAVED_MESSAGE_HANDLE
```

`message` accepts literal positional text, `-` for stdin, or `--text FILE` to capture a file. `requests` only lists local records; `recover` reuses the exact saved inputs after an uncertain reply, even if the input file changes. The private records live under `~/.config/rui/requests` and do not expire independently. A new message needs a new command/key; `follow` detaches without stopping work. Human commands default to Markdown-like text and accept `--json` (mutations emit complete newline-delimited capture and admission objects so the handle remains parseable if the reply is lost). Explicit `--record` and `--key` retain the original low-level JSON route. Workflow Session discovery waits for the Host Workflow inspection operation. The [Bash walkthrough](#try-the-implemented-development-path) still demonstrates the explicit-key route with a deterministic endpoint. `rui` without arguments prints exact usage.

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
- To change Session behavior or verify an implementation slice, find the owning behavior in Architecture and its required evidence in [Verification](VERIFICATION.md).
- To run or interpret qualification, start with [current qualification](tests/qualification/README.md#current-checks-and-qualification); it records revision-specific observations and their limits.
- To inspect design evidence or archived experiments, read [Research](research/README.md).
- Contributors should follow [working rules](AGENTS.md). Dependencies and notices live in [third-party notices](THIRD_PARTY_NOTICES.md).
