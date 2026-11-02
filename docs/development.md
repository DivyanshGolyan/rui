# Developing Rui

## Build from source

You need Zig 0.17.0, Python 3.11 or newer, Git, curl, Perl, `patch`, a C toolchain and Make. On macOS, install the Xcode command-line tools with `xcode-select --install`. Make sure `python3` on `PATH` is the newer Python, not Apple's Python 3.9.

To build the same source that releases use, install from `stable` in a clean checkout:

```sh
git fetch origin stable
git switch --detach origin/stable
./install.sh
```

If `~/.local/bin` is not on your `PATH`, the installer prints the line to add to your shell profile. To update, run the same commands again. `main` gets changes after Linux CI passes, before Mac and upgrade checks, so it can be ahead of `stable`.

`./install.sh` builds the current checkout, including local changes. It never fetches or switches branches. It pins native dependencies, builds into a new directory under `~/.local/lib/rui`, checks the result and then points `~/.local/bin/rui` at it. A failed build leaves the previous installation unchanged.

Installation keeps Stores, credentials, shell profiles and earlier builds, because a running Host may still use an earlier build. It starts and stops nothing. It reports only what needs action: a running Host and the command that can stop it, a Store format the new build cannot open, and a `PATH` that does not select the new command. A running Host keeps its old executable. To use the new one, let the Host's work finish, run the `host stop` command the installer printed, wait for `rui host status` to report unavailable, then start `rui` again.

If your shell still runs an older `rui`, check `type -a rui`, then run `rehash` in Zsh or `hash -r` in Bash.

## Build and test

After `./install.sh` has prepared the dependencies, build a development binary and run the portable checks:

```sh
zig build
zig build test-logic
```

The development binary is `zig-out/bin/rui`. To use it in place of the installed command, call it by that path.

To choose the checks a change needs, use [the subsystem test selector](../VERIFICATION.md#canonical-gates). Build and dependency changes, and release qualification, need more evidence. An old test result is not a pass for new code. For a build with empty caches, follow the [empty-cache steps](../VERIFICATION.md#canonical-gates).

The build uses stock Zig 0.17.0 and the pinned official `translate-c` package for C bindings. Compiler objects go in `ZIG_GLOBAL_CACHE_DIR`. Extracted dependencies go in `zig-pkg`, or in `ZIG_LOCAL_PKG_DIR` if set. Zig 0.17 removed `--global-cache-dir` from `zig build` and `zig fetch`.

### Editor support

ZLS does not work with this toolchain yet. As of October 14, 2026, ZLS master targets Zig 0.17 but disables build-configuration loading, tracked in [ZLS #3208](https://github.com/zigtools/zls/issues/3208). The latest ZLS release targets Zig 0.16. Use `zig fmt`, `zig build` and the selected test targets for compiler feedback. Rui does not support the experimental workaround, which needs a forked compiler.

## Try Rui without a provider account

```sh
zig build bash-walkthrough
```

The walkthrough prints real CLI commands, approves one Bash action and saves its answer. It then crashes its own Host and recovers the same result. It uses a deterministic local provider and deletes its temporary project and Store when it succeeds.

The crash happens after Rui has saved the result and cleanup. So the walkthrough checks saved-result recovery, not an interrupted command or power loss. See [the walkthrough's checks](../VERIFICATION.md#runnable-bash-caller-acceptance-audit).

## What's next

[Durable JavaScript workflows](https://github.com/DivyanshGolyan/rui/issues/273) are still in development. The [delivery plan](https://github.com/DivyanshGolyan/rui/issues/164) tracks feature work, separately from [full qualification](https://github.com/DivyanshGolyan/rui/issues/231).
