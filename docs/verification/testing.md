# Test requirements

[Verification](../../VERIFICATION.md) links here; this document owns what a Rui test must be and how the suite moves onto these rules.
Tracking issue: [#1729](https://github.com/DivyanshGolyan/rui/issues/1729).

Rui's tests are derived from its promises, not from its code or its bug history.
Each area keeps an invariant catalog: the promises a user or caller relies on, written top-down from the product level to each module.
Every test owns one catalog invariant, and every invariant has one owner test.
The approach follows Design by Contract (preconditions, postconditions and invariants define the system), specification-first design (write down the promise before the code), property-based testing (state what always holds and check it over generated inputs) and deterministic simulation (check invariants over a seeded world, with time passed in as a value).

## Invariant catalogs

Each area has `docs/invariants/<area>.md`, derived from the [README](../../README.md) and the area's contract under [docs/contracts](../contracts).
One row per invariant:

| Column | Content |
| --- | --- |
| Id | Area prefix and number, such as `ADM-3`; never reused |
| Level | Product, Host, Surface or Module (below) |
| Invariant | One sentence stating behavior a user or caller observes |
| Seam | The public boundary that observes it |
| Owner test | The single test that checks it, named as it appears in the source |
| Source | The contract section or owning `src` file |

A catalog is the smallest set of invariants that would catch every real bug in its area.
A contract change that adds or alters a promise changes the catalog in the same PR.

## What a test must be

A test is kept only when all of these hold:

1. **It owns one invariant.** It names its catalog id in its name or first line. A test with no invariant is deleted.
2. **It checks behavior through a public seam:** the CLI, the wire protocol, screen state, the Store file, or a module's public API. Renaming or moving a private function never breaks it.
3. **It fails only when its invariant breaks.** Every red is a bug in Rui or in the harness, and a harness bug is fixed at its root.
4. **It is deterministic:** the same result on Linux and macOS, alone or in parallel, run after run. No sleeps, no wall clock, no real network, no fixed ports, no state shared with another test.
5. **It sits at the lowest level that can observe its invariant.**
6. **It covers the rule's whole domain.** Many cases of one rule are one table-driven or property test over generated inputs, not one test per case.

## Levels

| Level | Promises | How it is tested |
| --- | --- | --- |
| Product | What a user gets end to end, such as one answer per message, no rerun after a crash during Bash, Sessions kept across an upgrade, the terminal restored after exit | Few scripted scenarios with real binaries, the scripted fake provider, an injected clock and a private Store. Only for what only a real process shows |
| Host | The Host's contract with any client: Store ownership, commit before reply, no lost or doubled input, wire compatibility | The Host in process, driven over the wire, with chosen times, a temporary Store and injected pause or crash points |
| Surface | What the CLI, the terminal UI and the TypeScript client show and accept | Pure render and parse functions over state snapshots: state in, text grid or exit status out. No PTY |
| Module | Each functional core's rule over its whole domain: encoders round-trip, policies decide consistently, state machines never reach a forbidden state | Unit and property tests; the existing model checks for concurrency protocols |

Most tests live at the Module and Surface levels; the Product level stays at tens of scenarios.

## Bugs refine the catalog

A bug shows that the catalog was missing a promise or stated it too loosely.
Its fix names the promise it broke, adds or sharpens that invariant at the right level, and extends the invariant's owner test.
No test exists only to replay one bug.

Provider wire classification is tested over the corpus in `src/testing/fixtures/provider-errors/`; each body states its provenance (captured, captured_redacted, documented or reconstructed); a new provider shape or refusal code enters as a corpus body, captured whenever one is available (import it from the Host's `diagnostics/failed-responses/` with secrets redacted), and the CI check refuses a refusal code with no body unless it is on the shrink-only uncaptured list.

## Flake sources and their root fixes

| Source | Root fix |
| --- | --- |
| Time: sleeps, timeouts, the wall clock | Time is a value: every decision that depends on time (deadlines, retries, expiry, dates) takes the current time as an argument, and only the imperative shell reads the clock. Tests pass chosen times and wait for events Rui emits, never a duration. A real timeout in a test is only a watchdog for a broken harness ([#1732](https://github.com/DivyanshGolyan/rui/issues/1732)) |
| PTYs and terminals | Screens are a pure function of state, tested without a PTY; the few Product PTY tests use one shared PTY owner |
| Shared processes and ports | Each test owns its Host, Store and socket path under its own temporary directory |
| Leftover state | A test's processes die with the test; nothing outlives it, including a killed Host's socket and `.store` hint in `/tmp/rui-<uid>`. Disposal through `stop_process` or `forced_crash_cleanup` retires the runtime entry before the Store is deleted; a fixture that kills a Host any other way must dispose through `stop_process`. `run_selected.py` fails a step that leaves one ([runtime_leftovers.py](../../tests/integration/runtime_leftovers.py), #1855) |
| Network and live providers | The scripted fake provider; live providers are manual, never a gate |
| Ordering and races | Inject the interleaving through a named pause point; never rely on the scheduler |
| Platform differences | Platform code sits behind one small seam; only that seam's tests run on both systems. Darwin limits that Linux CI copies are listed in [Darwin limits on Linux](#darwin-limits-on-linux) |

`tests/ci/flake_sources.py` enforces the flake-source rules with a shrink-only allowance.

A test that is flaky is fixed at its root or deleted.

## Darwin limits on Linux

Linux CI enforces these Darwin limits, so a Darwin-only red shows up without Mac minutes:

- Darwin-shaped temporary directory: `.github/actions/darwin-tmpdir` gives Linux CI Darwin's long `TMPDIR` path (#579, #724, #755).
- AF_UNIX send buffer: `os_semantics.unix_stream` limits unread send capacity to 4 KiB, as Darwin does (#1150).
- Bind without listen: `platform_boundary.bind_violations` refuses a fixture that binds a socket and never listens, since Darwin drops connections to it.
- AF_UNIX path length: every harness refuses a path of 104 bytes or more on every platform, through `os_semantics.check_unix_path` and its checked server and asyncio wrappers in Python, and `measurement.CheckUnixPath`, `ListenUnix` and `DialUnix` in Go (#1948). `platform_boundary` refuses any other Unix server or asyncio call outside `os_semantics`.
- pkg-config: dependency builds that run configure on Linux run with pkg-config hidden from PATH, as on the Mac runner, in `src/build_transport.sh` (#1932).

Rule only, not enforced on Linux: a fixture that listens without accepting sizes its listen backlog for every connect the test makes, because Darwin refuses a connect to a full backlog while Linux queues it (#1956).

## Migration

Existing tests that predate these rules are legacy.
They keep running until their area moves over, and nobody extends them.

Every PR that changes production logic moves the tests of the owners it touches onto these rules, in the same PR:

1. Add or update the catalog rows for the touched owners' promises.
2. Write or extend each row's owner test under the rules above.
3. Delete the legacy tests those rows replace, and point CI selection at the new tests.

A PR that touches production logic and leaves its owners' legacy tests in place says why in its body.
Documentation, CI and test-only PRs carry no migration duty.
