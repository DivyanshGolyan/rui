# Throwaway Session API protocol experiment

Question: can a workflow use idempotent core admission without a shared workflow/core transaction, including cancellation of unanswered calls?

Run `python3 research/session-api-prototype/prototype.py` from the repository root. Python standard library only. Temporary core and workflow SQLite files are separate and removed afterward. Child processes exit abruptly at selected boundaries; subsequent child processes reopen the files. Only synthetic pending/stopped work is modeled; no provider request, shell command or file edit executes.

## Checks and results

See [results.json](results.json) for the executed output. All checks passed:

- Exit before core commit leaves neither request nor work.
- Exit after core commit but before reply: fresh-process matching retries return the original work reference, with exactly one work row.
- Changed inputs conflict without replacing the binding.
- A committed missing-Session rejection remains unchanged after that Session is created.
- Workflow cancellation resolves one committed-but-unanswered call and one never-delivered call. Exit after stopping but before cancellation completion, followed by restart, admits no duplicate work and records completion only after all answers are known.
- Session-wide stop includes direct work sharing the Session; this is the accepted policy, not per-workflow isolation.

## Limits

This is an executable protocol model, not OnePage production code or an end-to-end test. Stop completes immediately in the model; real effect cleanup, permissions, configuration, Session creation API, progress/wait transport, busy concurrency, storage failures, power-loss behavior, key namespace generation and byte-stream canonicalization are not tested. SQLite FULL synchronization is used, but process exits do not certify hardware durability. Separate database files demonstrate the absence of a cross-store transaction in this model, not a selected deployment topology.

No architecture decision requires a new request interpreter, broker or separate process merely because the prototype uses command-line child processes to inject crashes.
