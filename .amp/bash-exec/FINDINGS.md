# Bash launch: `-c` exec-last, argv limits and launch hygiene — findings, 22 Oct 2026

Lane: [T-01a162a1](https://ampcode.com/threads/T-01a162a1-8f42-75f1-959c-ac80ad5eda51). Base: origin/main `671c3c7d`. "Source" means public source read at the cited tag; "docs" means vendor documentation; "inference" is labelled.

## How agents launch tool commands

| Agent | Evidence kind | Launch |
| --- | --- | --- |
| Codex (`openai/codex`, codex-rs) | Source | `[shell, "-lc", cmd]` (login) or `[shell, "-c", cmd]` for bash/zsh/sh: [core/src/shell.rs#L22-L51](https://github.com/openai/codex/blob/main/codex-rs/core/src/shell.rs#L22-L51), chosen in [unified_exec.rs#L97-L123](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/unified_exec.rs#L97-L123). Child gets `setsid()` (fallback new pgrp), `/dev/null` stdin, piped stdout/stderr, group `SIGKILL` cleanup: [core/src/spawn.rs#L70-L136](https://github.com/openai/codex/blob/main/codex-rs/core/src/spawn.rs#L70-L136), [utils/pty/src/process_group.rs](https://github.com/openai/codex/blob/main/codex-rs/utils/pty/src/process_group.rs). exec-server only accepts stdin writes with `tty`/`pipeStdin` ([exec-server/src/local_process.rs#L631-L690](https://github.com/openai/codex/blob/main/codex-rs/exec-server/src/local_process.rs#L631-L690)). No script file. |
| Claude Code | Docs only; implementation is closed source ([LICENSE.md](https://github.com/anthropics/claude-code/blob/main/LICENSE.md)) | [Tools reference](https://code.claude.com/docs/en/tools-reference#bash-tool-behavior): each command runs in a separate process with a captured shell snapshot; env vars do not persist. [`CLAUDE_CODE_SHELL` wrapper example](https://code.claude.com/docs/en/env-vars) receives one command string in `$1` and runs `exec bash -c "$1"`. **Inference only:** a command-string `-c` launch; the exact argv is undocumented. |
| OpenCode (`sst/opencode`) | Source | POSIX shells get `["-c", command]`: [packages/core/src/shell/select.ts#L164-L169](https://github.com/sst/opencode/blob/dev/packages/core/src/shell/select.ts#L164-L169). |
| Goose (`block/goose`) | Source | `["-c", command_line]`, child-led group, group `SIGKILL` on timeout: [developer/shell.rs#L92-L95](https://github.com/block/goose/blob/main/crates/goose/src/agents/platform_extensions/developer/shell.rs#L92-L95), [shell_process.rs#L51-L90](https://github.com/block/goose/blob/main/crates/goose/src/agents/platform_extensions/developer/shell_process.rs#L51-L90). |
| Rui (main `671c3c7d`) | Source | `[bash_path, <scratch>/bash-input-A-N.tmp]`, group leader, `/dev/null` stdin: [src/bash.zig#L247](../../src/bash.zig). Script mode never enters Bash's `-c` ONESHOT path. |

## Bash exec-last rules

- **5.1/5.2 source** (`bash-5.2` tag, [builtins/evalstring.c](https://cgit.git.savannah.gnu.org/cgit/bash.git/tree/builtins/evalstring.c?h=bash-5.2)): `should_suppress_fork` requires `startup_state == 2` (`-c`), first-level `parse_and_execute`, the whole string consumed and no alias expansion; `should_optimize_fork` requires no running trap, `cm_simple`, no EXIT/ERR or other trapped signal, no redirections, no `time`, no `!`. `can_optimize_connection` extends this to the right side of `;`, `&&`, `||` and rechecks traps when that branch is selected. [NEWS (5.1)](https://cgit.git.savannah.gnu.org/cgit/bash.git/tree/NEWS?h=bash-5.2): "optimize the number of times it forks when executing commands in subshells and from `bash -c`".
- **Upstream test** [tests/exec14.sub#L15-L64](https://cgit.git.savannah.gnu.org/cgit/bash.git/tree/tests/exec14.sub?h=bash-5.2#n15) with [tests/exec.right](https://cgit.git.savannah.gnu.org/cgit/bash.git/tree/tests/exec.right?h=bash-5.2): list optimization must not skip later commands or an EXIT trap set earlier in the list.
- **3.2 source** (macOS `/bin/bash` 3.2.57, [Apple bash-92 version.h](https://github.com/apple-oss-distributions/bash/blob/bash-92/version.h#L4-L14)): ONESHOT only when the *whole* `-c` string is one simple command, with no EXIT trap, no redirections, no time/invert ([evalstring.c#L244-L270](https://github.com/apple-oss-distributions/bash/blob/bash-92/bash-3.2/builtins/evalstring.c#L244-L270)). Lists are never optimized. **Stock macOS therefore saves the parent only for single-command calls.**
- **Installed here** (orb, GNU bash 5.2.15; CI ubuntu-24.04 ships 5.2.21, not run here). Observed `/proc/<leader>/comm` 0.3 s after `bash -c CMD bash`:

| `CMD` | Leader | Leader's children |
| --- | --- | --- |
| `sleep 2` | sleep | none |
| `echo a >/dev/null; sleep 2` | sleep | none |
| `cd /tmp && sleep 2` | sleep | none |
| `false \|\| sleep 2` | sleep | none |
| `sleep 2; echo END` | bash | sleep |
| `trap "echo x" EXIT; sleep 2` | bash | sleep |
| `sleep 2 \| cat` | bash | sleep, cat |
| `sleep 2 >/dev/null` | bash | sleep |
| `x=1; sleep 2 2>&1` | bash | sleep |
| `{ sleep 2; }`, `f(){ sleep 2; }; f` | bash | sleep |
| `sleep 2 &` | (exited) | sleep orphaned in the group |
| script file `bash s.sh` containing `sleep 2` | bash | sleep |

So a trailing marker, an EXIT trap, a pipeline, a redirection on the final command, a brace group or a function all keep Bash resident; background jobs stay in the original process group in both modes.

## Linux argv limits

- [include/uapi/linux/binfmts.h#L9-L16 (v6.1)](https://github.com/torvalds/linux/blob/v6.1/include/uapi/linux/binfmts.h#L9-L16): `MAX_ARG_STRLEN = PAGE_SIZE * 32` (131072 with 4 KiB pages, the smallest Linux page size Rui targets).
- [fs/exec.c `copy_strings` #L525-L541](https://github.com/torvalds/linux/blob/v6.1/fs/exec.c#L525-L541) and [`valid_arg_len` #L291-L294](https://github.com/torvalds/linux/blob/v6.1/fs/exec.c#L291-L294): length from `strnlen_user` **includes the NUL**; over-length returns `-E2BIG`. Maximum one argument: 131071 bytes plus NUL.
- [fs/exec.c `bprm_stack_limits` #L471-L509](https://github.com/torvalds/linux/blob/v6.1/fs/exec.c#L471-L509): total argv+envp strings ≤ `max(ARG_MAX=128 KiB, min(¾·_STK_LIM, RLIMIT_STACK/4)) − (max(argc,1)+envc)·sizeof(void*)`.
- Measured here (kernel 6.1, 4 KiB pages): `bash -c <131071 B>` runs, `<131072 B>` fails `E2BIG`. With `RLIMIT_STACK` 256 KiB or 512 KiB the total floor binds: 131071 B fails even with a near-empty environment; 122880 B succeeds with 8000 B of extra environment and fails with 9000 B. With the default 8 MiB stack the total limit is 2 MiB.
- macOS has no per-string limit; `ARG_MAX` is a total (1 MiB). Linux binds.

## Rui's command size and admission path

- The only bound on `cmd` today is the canonical argument blob, up to `max_sqlite_content_bytes` (≈1 GiB, [src/protocol.zig#L23](../../src/protocol.zig)). [`tools.BashParser`](../../src/tools.zig) is the only decoder; it rejects raw bytes < 0x20 and `\u0000`, so a decoded command never contains NUL. Bytes ≥ 0x80 pass through unvalidated, which argv accepts.
- Every launch goes `startPreparation → Preparation.advance → Prepared.launch` ([src/server.zig](../../src/server.zig) `dispatchBash`/`advanceBashPreparation`/`launchPreparedBash`). No other path builds Bash argv.
- 1 GiB is far above 128 KiB, so deletion of the script file needs a cap. **Choice: 122,880 bytes (120 KiB) of decoded command**, rejected during preparation, before launch, as `spawn_failed` with an explicit size message. The 8 KiB below the per-string limit covers Rui's typical argv/environment (bash path, `-c`, `$0`, PATH, HOME, RUI_ADDRESS, pointers) under the kernel's 128 KiB total floor when `RLIMIT_STACK` ≤ 512 KiB. Pathological environments under such a stack still fail as ordinary `E2BIG` → `spawn_failed`. No file fallback, no truncation.

## Launch hygiene in the pinned Zig 0.17.0 std

- Rui's Host uses `std.Io.Threaded` (from `std.process.Init`). Linux path `spawnPosix` ([lib/std/Io/Threaded.zig#L15282-L15475](file:///home/user/.local/opt/zig-0.17.0/lib/std/Io/Threaded.zig)): fork, `chdir`, `dup2`, `setpgid`, `execve`. **No signal-mask or disposition reset.** The child inherits the forking thread's mask and every `SIG_IGN` disposition.
- `getDevNullFd` (#L15485-L15500) opens `/dev/null` `O_RDWR` **without `O_CLOEXEC`** and caches it in `Threaded.null_file`; every later child of any spawn inherits it.
- macOS path `spawnDarwin` (#L17396-L17600) uses `posix_spawn` with only `SETPGROUP`/`SETEXEC`/`START_SUSPENDED`: no `SETSIGMASK`/`SETSIGDEF`, no `CLOEXEC_DEFAULT`, and the same cached `/dev/null`.
- Rui itself sets SIGCHLD to `SIG_DFL` at Host start and scopes other signal changes to threads/CLI. Ignored dispositions still arrive from whoever started the Host (`nohup` ignores SIGHUP; a non-interactive shell's `&` ignores SIGINT/SIGQUIT), and Bash cannot un-ignore signals ignored at entry.
- Fix direction: a Rui-owned `posix_spawn` for Bash with `POSIX_SPAWN_SETSIGMASK` (empty) and `POSIX_SPAWN_SETSIGDEF` (all), `/dev/null` opened by a file action, pipes CLOEXEC. This does **not** close unrelated inherited non-CLOEXEC descriptors and is not claimed to be faster.
