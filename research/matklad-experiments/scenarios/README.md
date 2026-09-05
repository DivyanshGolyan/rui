# Reusing recovery scenarios without simulating the runtime

> **Historical experiment published 6 September 2026.** See the [publication notes](../PUBLICATION.md) for current contract ownership, preserved evidence, privacy substitutions, and reproduction limits.

Run from the repository root:

```sh
python3 research/matklad-experiments/scenarios/run.py
```

Requires the project's Zig 0.16, Python 3.12+, Git, and the repository's pinned SQLite dependency (the runner uses the cached package, fetching with Zig only if absent). It compiles the unmodified production effect and patch fixtures with ReleaseSafe and SQLite macros read from `build.zig`, creates disposable state directories and Git repositories, runs each step in a fresh process, and writes `results.json`. Generated dependencies, binaries, and cache stay in ignored `generated/`. No provider/network requests occur during scenarios. Dependency fetching, if needed, uses the pinned URL/hash.

## Question and answer

Can a small reusable checker preserve behavior-level recovery evidence without building a parallel runtime model? Yes: the existing production fixtures already supply the necessary adapters. The experiment groups eight executions into four families: model publication/recovery, uncertain versus authorized Bash, patch reconciliation, and retry/late evidence. Scenario data names actions and expected observations; Python owns only process invocation, temporary workspace setup, result checking, and recording. Zig owns every admission, transaction, recovery, and effect decision.

This is mostly evidence to **retain and adapt existing fixtures**, not justification for a new scenario framework. `src/effect_recovery_integration.sh` and `src/patch_recovery_integration.sh` already provide similar process orchestration in less code. The experiment adds centralized reports and negative controls, but also incurs build-discovery code and another language. Keep that machinery experimental unless reporting becomes an actual need.

## What is exercised

| Case | Actual boundary and assertion |
|---|---|
| Candidate not published | Existing fixture exits 86 after model dispatch without Zig cleanup; fresh-process recovery finds no authoritative Completion/candidate and dispatches one new Attempt. |
| Transaction not committed | Existing fixture exits 88 before SQLite commit; reopened database does not acquire partial completion authority. |
| Completion published | Existing fixture exits 87 after completion publication; reopen preserves exact bytes and finishes with zero provider redispatches. |
| Uncertain Bash | An actual shell appends `x`, then injected error unwinds/closes; two fresh-process resumes report indeterminate and file remains exactly `x`. |
| Authorized Bash | Error after authorization but before execution; file is absent until resume, which dispatches the real shell once. |
| Patch postimage | Actual patch changes `old` to `new`, then injected error unwinds/closes; reopen reconciles expected postimage, and repeated finished resume changes nothing. |
| Patch divergence | Error after Attempt admission; external edit changes file to `mine`; recovery reports an indeterminate tool Result and preserves external bytes. |
| Model retry/late evidence | Error after dispatch; fresh-process completion produces a second Attempt; submitting old evidence does not advance historical sequence or Attempt count. |

The first three are real abrupt process exits, not externally delivered SIGKILL. Bash/patch/ordinary retry faults explicitly unwind and close; their results are not abrupt-crash evidence. None proves OS power-loss durability. Exit statuses and observation results are recorded in `results.json`.

Two negative controls run: changing `uncertain.txt` to `xx` must fail the same file checker, and presenting a published completion to the fixture's unpublished-candidate recovery oracle must fail. These demonstrate sensitivity to duplicate visible side effects and the wrong publication-authority classification; they do not constitute mutation testing of all runtime faults.

## Coupling and limits

The observable obligations transfer to the proposed runtime: uncertain Bash is not replayed, exact committed evidence survives restart, patch reconciliation preserves divergence, and late evidence cannot overwrite accepted results. Fixture modes, `semanticView`, ledger sequence numbers, `expectModelAttempts`, and terminal Session state do not transfer unchanged. `src/session_transition_test.zig:6` directly asserts historical fact-tag numbering, while the effect fixture's late-evidence oracle (`src/effect_recovery_fixture.zig:411`) reads historical ledger state. Those are implementation tests, not a portable product contract.

The snapshot `../contracts/README.md:30` explicitly says relational reusable Sessions/Turns and disk-first Host Runtime are unimplemented. New Session-stop versus provider-settlement ordering and cleanup retaining Physical Custody therefore cannot be exercised here. A fabricated replacement state machine would only prove the fabrication. No claims about proposed parser memory, custody memory, replay schema, live providers, or release certification follow from this experiment.

## Recommendation

Preserve the current small real-runtime fixtures and adapt their internal oracles during the relational rewrite. Add one production fault hook where a promised failure boundary lacks one; avoid exposing more runtime internals merely for tests. Keep feature expectations in compact data when several tests share the exact same setup, but leave effect-specific checks in the adapter rather than growing a generic action language.

### [TEST-01] Carry behavior scenarios through the relational rewrite

- **Evidence**: `src/effect_recovery_fixture.zig:155` restores real storage and checks candidate authority; `src/effect_recovery_fixture.zig:280` rejects provider redispatch after committed publication; `src/patch_recovery_fixture.zig:84` resumes through the real Harness; this experiment records successful repeated process execution and rejected negative controls.
- **Impact**: Retains useful recovery obligations while avoiding a parallel simulator and prevents replacing meaningful behavior checks with schema-only tests. No measured production-memory savings are claimed.
- **Effort**: S to preserve scenario data and adapt a first implementation slice; the full adapter migration depends on the rewrite.
- **Risk**: LOW for retaining observations; MED if historical ledger internals are accidentally treated as normative.
- **Confidence**: HIGH that current interfaces support shared process orchestration; no evidence that an additional test framework is necessary.
- **Fix sketch**: Reuse existing fixture programs and stable effect/file outcomes. Replace their ledger-specific assertions with production relational queries as each implementation slice lands; add new stop/custody scenarios only against those implemented owners.
