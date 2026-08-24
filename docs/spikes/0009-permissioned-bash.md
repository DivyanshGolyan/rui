# Permissioned Bash and second model turn

## Question

Can OnePage authorize and execute one real shell call without widening the tool vocabulary, retaining
an agent page while the process runs, leaking inference credentials, or guessing after a crash?

## Call and permission contract

The model emits one canonical `bash` item containing exactly one UTF-8 command of at most 2,048 bytes
and an explicit timeout from 100 ms through 120 seconds. The host validates those bytes, stores the
immutable descriptor, computes its SHA-256-derived durable digest, and records
`descriptor_validated` before consulting policy.

Policy independently classifies the exact `{digest, command, timeout}` subject as `allow`, `ask`, or
`deny`. The product CLI asks by default and prints those exact fields; `--allow-bash` exists for the
deterministic demo. The decision is durable before an allowed Attempt is created. A denied call does
not spawn a process and becomes a typed Result that the model can observe on turn two.

## Execution and result contract

An allowed consequential Attempt is synced before `/bin/bash --noprofile --norc -c` starts. Bash runs
in its own process group, and timeout, cancellation, or output overflow kills and reaps that whole
group before a Result is published. A host cancellation signal is wired through the real agent path,
not merely represented in the result codec. It runs from the Session's
bound Git worktree with an environment containing only `PATH=/usr/bin:/bin`, `LC_ALL=C`, and
`ONEPAGE_SANITIZED=1`; inference and unrelated host credentials are absent. The command cannot select
its cwd or timeout outside its validated descriptor.

Stdout and stderr are independently bounded at 64 KiB. Success, nonzero exit, timeout, cancellation,
missing executable, truncation, denial, indeterminate execution, and spawn failure have distinct
canonical statuses. The complete bounded output is placed in an immutable result blob. The Attempt
result is then synced. The conversation contains the assistant's exact immutable tool call followed
by its correlated `tool_result`; only then does the core commit both entries and choose the expanded
root-to-leaf context for model turn two. The execution page is checkpointed and released while Bash
runs.

The fixture verifies the actual second request contains a canonical successful Bash Result; it is not
a timed transcript. Search, inspection, and verification remain ordinary shell commands rather than
new tools.

## Crash semantics

A crash after Attempt start and process return but before result publication is deliberately not
replayed. Resume first reconciles the model completion, detects the unmatched consequential Attempt,
appends one `attempt_indeterminate` record, and returns `BashPossiblyExecuted`. Repeated resume returns
the same disposition without another process. The integration command appends one byte to a real file
and proves two resumes leave exactly one byte.

This is an honest at-most-one-automatic-attempt rule, not an exactly-once claim. A future interactive
reconciliation surface may let the user inspect the worktree and start a new approved Attempt.

Once an allowed or denied result record is durable, finalization is replayable: crashes before the result entry, after
the entry, or after the tool checkpoint reconcile the same call/result pair and continue through a
provider-backed resume without executing Bash again.

## Bounds and proof

- core linear memory remains exactly 65,536 bytes with growth disabled;
- ReleaseSmall core has 29 function exports and 154 data-section bytes;
- command bytes: at most 2 KiB;
- resident collected stdout/stderr: at most 64 KiB each;
- operation records: fixed 80 bytes;
- model turns in the demo: exactly two;
- concurrently active effects per agent slot: one.

`zig build test -Doptimize=ReleaseSafe` covers call validation, permission binding, environment
sanitization, success, nonzero exit, timeout, missing executable, truncation, cancellation encoding,
denial without execution, real second-turn context, exact resume, and indeterminate no-replay.
`zig build fixture-bash -Doptimize=ReleaseSmall` is the visible end-to-end demonstration.
