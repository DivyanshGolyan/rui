# Linting and typechecking setup for OnePage

Research date: 2026-08-25
Repository revision: `8c0d694bac7da3ced525e3a479d7252a32f1224f`
Toolchain evaluated: Zig 0.16.0

## Adoption status

The compiler-first gate, scoped engineering style, and pinned macOS ARM64 CI were adopted on
2026-08-25. Declaration-discovery coverage is deferred until the Core and Harness module graphs
stabilize in issues #14 and #15 and is tracked by issue #16. ZLint remains outside V1 unless a later
pilot demonstrates unique, low-noise defects.

## Decision

OnePage should make the Zig compiler its primary linter and typechecker, add a small compiler-backed `check` step, and run that step in pinned macOS CI. It should not adopt a broad third-party lint preset yet.

The recommended required checks are:

```sh
zig fmt --check --ast-check build.zig src
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSmall --summary all
```

The first command is a fast formatting and syntax gate. The second compiles and runs the safety-enabled test graph. The third compiles the three shipped artifacts in their actual size-optimized, safety-disabled mode. These checks are complementary: Zig documents `ReleaseSafe` as optimized with safety checks and `ReleaseSmall` as size-optimized with safety checks disabled ([Zig 0.16.0 build modes](https://ziglang.org/documentation/0.16.0/#Build-Mode)).

Add declaration-discovery coverage next. Trial ZLint only as an explicitly configured, initially non-blocking second layer; promote individual rules after their baseline findings have been reviewed.

## Current baseline

The repository has 22 tracked Zig files and 71 test declarations. Its build graph creates a fixed `ReleaseSmall` Wasm core, two native executables, 12 native test artifacts, a Wasm contract check, and an end-to-end agent executable ([current `build.zig`](../../build.zig)). The README requires macOS on Apple Silicon and Zig 0.16.0 ([current requirements](../../README.md#requirements)).

At the researched revision:

- `zig fmt --check --ast-check build.zig src` passed.
- `zig build test -Doptimize=ReleaseSafe --summary all` passed all 166 tests and the integration/contract executables.
- `zig build -Doptimize=ReleaseSmall --summary all` compiled all three installable artifacts.
- There is no CI workflow, formatter/check build step, linter configuration, `build.zig.zon`, or other machine-enforced toolchain pin.

The project is already clean. The gap is repeatable enforcement and analysis coverage, not a backlog of compiler errors.

## Recommended setup

### 1. Add one canonical `zig build check` step

Make `check` the local and CI contract, with dependencies on:

1. a `std.Build.Step.Fmt` step configured with `check = true` over `build.zig` and `src`;
2. the existing ReleaseSafe test and integration graph;
3. install/compile steps for the native deliverables in `ReleaseSmall`.

Zig's formatter is the language's canonical style implementation: the language reference says `zig fmt` implements its source-format recommendations ([Zig source encoding and formatting](https://ziglang.org/documentation/0.16.0/#Source-Encoding)). The build-system guide also distinguishes compiling a test artifact from running it: tests execute only when an `addRunArtifact` dependency exists ([official build-system testing guide](https://ziglang.org/learn/build-system/#Testing)). OnePage already wires those run edges correctly; the new step should reuse that graph rather than invoke separate ad hoc commands.

`--ast-check` is worth keeping in the formatter command. On Zig 0.16.0 it asks `zig fmt` to run `zig ast-check` on every input, catching source-level compile errors without target information or typechecking. It is extremely cheap on this repository, but it is not a substitute for `zig build`.

Tradeoff: `ReleaseSafe` tests plus a `ReleaseSmall` artifact build duplicate some compilation. That duplication is intentional because the shipped mode disables runtime safety and can exercise different compilation/code-generation paths. Do not add `ReleaseFast` until OnePage ships or benchmarks that mode; it would add cost without covering a real deliverable.

### 2. Close Zig's lazy-analysis gap explicitly

Add a small compile-coverage root that imports every first-party source file and calls `std.testing.refAllDecls` for each imported namespace, then attach it to `check` as a test compile/run step.

Zig 0.16.0 discovers imports, tests, and declarations lazily: a named declaration is analyzed when a reference to it is analyzed, and the official guidance uses imports inside `comptime` or `test` blocks to force file discovery ([file and declaration discovery](https://ziglang.org/documentation/0.16.0/#File-and-Declaration-Discovery)). The standard library's `refAllDecls` exists specifically to reference every declaration so the semantic analyzer sees it ([Zig 0.16.0 source](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/testing.zig#L1213-L1218)).

This matters here because a green build proves the declarations reached by the current executable and test roots; it does not mean every dormant declaration body or generic instantiation has been analyzed. `refAllDecls` improves non-generic declaration coverage, but it still cannot invent meaningful generic type combinations. Keep focused behavior tests for generic APIs and platform branches.

Tradeoff: maintaining an explicit import list creates one small update obligation when a source file is added. That is useful friction: a CI failure makes source-to-check coverage visible instead of relying on incidental imports.

### 3. Enforce the contract in pinned macOS CI

Use a single macOS ARM64 job initially because the repository explicitly supports Apple Silicon and dynamically loads Apple's JavaScriptCore framework. GitHub currently documents `macos-14`, `macos-15`, and `macos-latest` as ARM64 hosted-runner labels ([GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)). Prefer a fixed label such as `macos-15`, not `macos-latest`.

The job should:

- check out the repository;
- install exactly Zig 0.16.0;
- run `zig build check --summary all`;
- grant only `contents: read` permissions;
- pin third-party actions to reviewed full commit SHAs.

`mlugg/setup-zig` supports an explicit compiler version, and its current v2 release line supports modern Zig downloads ([setup-zig releases](https://github.com/mlugg/setup-zig/releases)). GitHub recommends full-length action SHAs because tags can move ([GitHub Actions security guidance](https://docs.github.com/en/code-security/tutorials/secure-your-organization/protect-against-threats#pin-actions-to-a-full-length-commit-sha)).

An optional `build.zig.zon` can advertise `.minimum_zig_version = "0.16.0"`, but it must not be treated as the enforcement mechanism: Zig's manifest documentation calls that field advisory and says the compiler does not currently act on it ([official manifest documentation](https://github.com/ziglang/zig/blob/master/doc/build.zig.zon.md#minimum_zig_version)). The exact CI installer input is the real pin.

Do not add Linux or Intel macOS to the required matrix until those targets are claimed as supported. The freestanding Wasm core is portable, but the current host/CLI integration is a macOS product contract.

### 4. Pilot ZLint with a curated configuration, not its defaults

ZLint is compatible with Zig 0.16.0; the current v0.9.1 manifest declares that minimum, and the tool uses an analyzer independent of the compiler, including code the compiler may not reach through lazy analysis ([v0.9.1 manifest](https://github.com/DonIsaac/zlint/blob/v0.9.1/build.zig.zon), [project design](https://github.com/DonIsaac/zlint#features)). That makes it a useful supplement, not a typechecker replacement.

A current ZLint trial over all tracked sources produced 34 warnings and no errors. Most are poor candidates for an immediate gate:

- 12 `no-print` findings are mostly intentional output in the CLI/spike host;
- 11 `unsafe-undefined` findings include fixed buffers and values initialized by APIs;
- 6 `suppressed-errors` findings are mostly deliberate best-effort cleanup, process termination, or thread yielding;
- one `no-catch-return` finding is a straightforward simplification.

Recommended pilot policy:

- enable `no-unresolved` as an error; it checks file imports even when compiler discovery does not reach the file, while documenting that build-added module imports are outside its scope ([rule documentation](https://raw.githubusercontent.com/DonIsaac/zlint/v0.9.1/apps/site/docs/rules/no-unresolved.mdx));
- keep `unsafe-undefined` as a warning and require `SAFETY:` explanations only where initialization is non-obvious. The rule explicitly allows justified use and warns that ZLint does not yet have a typechecker ([rule documentation](https://raw.githubusercontent.com/DonIsaac/zlint/v0.9.1/apps/site/docs/rules/unsafe-undefined.mdx));
- trial `unused-decls` as a warning, not an error, because its own documentation lists incomplete member-access and method-call analysis ([rule documentation](https://raw.githubusercontent.com/DonIsaac/zlint/v0.9.1/apps/site/docs/rules/unused-decls.mdx));
- trial `returned-stack-reference` as non-blocking only: it targets a severe bug class, but upstream labels it `nursery`, off by default, and early in development ([rule documentation](https://raw.githubusercontent.com/DonIsaac/zlint/v0.9.1/apps/site/docs/rules/returned-stack-reference.mdx));
- disable `no-print` for this repository and do not gate on the full default preset;
- review `suppressed-errors` findings manually. The rule rejects empty catches, but OnePage has legitimate cleanup paths where the right improvement is an explanatory comment or narrow suppression, not error propagation ([rule documentation](https://raw.githubusercontent.com/DonIsaac/zlint/v0.9.1/apps/site/docs/rules/suppressed-errors.mdx)).

Pin the ZLint version/checksum if the pilot enters CI. Keep it non-blocking for at least one baseline cleanup change; promote a rule only after every existing diagnostic has been classified and intentional suppressions explain why.

## Suggested rollout

1. Add `zig build check` with format/AST, ReleaseSafe tests, and a ReleaseSmall artifact compile.
2. Add the declaration-discovery test root.
3. Add pinned macOS ARM64 CI and make `check` required.
4. Add a pinned ZLint trial with only `no-unresolved` blocking; keep the reviewed safety rules informational.
5. After the baseline is annotated, decide rule by rule whether ZLint is earning its maintenance and false-positive cost.

This sequence gives OnePage a strong, nearly dependency-free correctness gate first. The third-party analyzer remains easy to remove if its independent coverage does not produce useful findings.
