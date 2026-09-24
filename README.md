# Rui

Rui (रुई, Hindi for cotton) is a local runtime for coding-agent workflows. It keeps reusable conversations working after clients disconnect and recovers durable work after crashes with bounded memory and temporary storage. Zig owns execution and recovery; SQLite stores durable state.

## Status

Rui is in development. Today the direct CLI can configure reusable Sessions, queue messages, receive text-model responses, stop or interrupt work, inspect proposed tools, authorize Bash and read saved results. Keyed requests, permission decisions and admitted work survive restart.

The precise model is documented in [Architecture](ARCHITECTURE.md): valid Bash descriptors become inspectable Actions, unknown tools and invalid descriptors become stable call-local rejections, and a Bash attempt that loses local custody resolves as indeterminate rather than replaying automatically.

JavaScript workflows, Edit and structured answers are not implemented. Rui-owned Codex login/refresh protocol parsing, private credential persistence and managed transport have deterministic/native fixture coverage; the authentication HTTP exchange and an authenticated live journey on Linux and macOS remain unqualified. Do not treat this as qualified live provider support. Bash process-group stopping cannot contain detached descendants. Retained full output is optional: FIFO eviction or restart may remove it without changing the saved result. Live-provider, power-loss and complete 1,000-operation mixed qualification remain outstanding.

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

For the implemented but unqualified Codex route, `rui login codex` prompts for a device code and stores credentials under `~/.config/rui/codex.json` in a private directory. `RUI_CODEX_CREDENTIAL_FILE` may select another absolute path under an owner-only directory. Device authentication must be enabled for the account/workspace. `rui serve --store /absolute/path/to/private-store --active-capacity 8 --codex` then selects only the fixed ChatGPT subscription route; it does not attach credentials to a development endpoint. Configure a Session with an exact model, `--tools bash` or `--tools none`, and text output; Edit and output schemas are rejected before dispatch in managed mode. A failed or interrupted refresh may require an explicit new login. These commands describe the implemented interface, **not** a live quickstart or model-availability claim.

`zig build codex-integration` exercises a synthetic credential, exact Bash approval, private continuation and fresh-Host recovery through public callers. `zig build codex-h2-integration` additionally needs Python `h2==4.3.0` and OpenSSL and checks managed TLS/HTTP2 negotiation, connection reuse and conditional FedRAMP routing. Neither uses live credentials.

An authorized native qualification can run `python3 tests/integration/codex_live.py /absolute/path/to/rui --live --model EXACT_MODEL` separately on Linux and macOS. It prompts for Rui-owned device login, approves only its exact inspected harmless Bash proposal and reports payload-free observations; it is not in ordinary build gates. Until both journeys pass, this is not a qualified live-provider quickstart.

## Try the implemented development path

Run the narrated public-caller journey from issue [#260](https://github.com/DivyanshGolyan/rui/issues/260): configure an ask-mode Session, submit a message, inspect and approve one exact Bash Action, read its saved answer, crash the Host, then recover the original submission without repeating the effect.

```sh
zig build bash-walkthrough
```

The prerequisites are the same as [Build](#build). The walkthrough prints the actual `configure`, `message`, `inspect-session`, Action-read, `allow-action`, `read-result` and `retry` commands with their observations. It creates an explicit temporary Workspace and Store, starts only its own local Host and deterministic provider endpoint, and removes those owned resources on success. The Workspace is a working directory, not a sandbox. Acceptance is not completion, and approval authorizes only the inspected Action.

This development smoke check is not a live-provider quickstart or power-loss test. Its process crash occurs after the result and effect cleanup are committed; the fresh Host proves recovery of those saved facts without another Bash or provider effect. See the [acceptance audit and limits](VERIFICATION.md#runnable-bash-caller-acceptance-audit). Run `zig build bash-integration` for the full maintained Bash journey.

## Development direction

The [delivery plan](https://github.com/DivyanshGolyan/rui/issues/164) separates [direct-core development readiness](https://github.com/DivyanshGolyan/rui/issues/168) from [full qualification](https://github.com/DivyanshGolyan/rui/issues/231). Essential safety evidence stays with each capability; broad qualification does not block independent feature development after the readiness checkpoint. Full stage, support, performance and release claims still require their evidence.

The runnable #260 slice and deterministic/native implementation of the [Codex path](https://github.com/DivyanshGolyan/rui/issues/272) are described above. Authenticated native Linux/macOS qualification still gates that issue's closure. A [minimal durable workflow](https://github.com/DivyanshGolyan/rui/issues/273) remains planned; these links do not expand the implemented surface described in [Status](#status).

## Read next

- To explain ordinary work, recovery, ownership or resource policy, read [Architecture](ARCHITECTURE.md).
- To change Session behavior or verify an implementation slice, find the owning behavior in Architecture and its required evidence in [Verification](VERIFICATION.md).
- To run or interpret qualification, start with [current qualification](tests/qualification/README.md#current-checks-and-qualification); it records revision-specific observations and their limits.
- To inspect design evidence or archived experiments, read [Research](research/README.md).
- Contributors should follow [working rules](AGENTS.md). Dependencies and notices live in [third-party notices](THIRD_PARTY_NOTICES.md).
