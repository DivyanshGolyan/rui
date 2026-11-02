# Installer output on first install and upgrade

Inspected 2026-10-31 as input to the wording of Rui's `curl … | sh` installer. It supplements [the clig.dev comparison](cli-guidelines-rui.md), which covers general help, output, error and prompt guidance for Rui commands. This note covers only what an installer prints. [Architecture](../ARCHITECTURE.md#store-format-and-upgrades) owns Rui's accepted behavior. When this note was written, it said "the installer reports Host status" (`ARCHITECTURE.md:581` at `fc621e51`, the commit every line reference below uses). The installer report that replaced that sentence drew on the recommendations below; they are not requirements.

Every installer was read from its own source, pinned to a release tag or commit. The one exception is flyctl: its script is served from `fly.io` and is absent from the flyctl repository at `v0.5.1`. That copy is identified by its SHA-256. The scripts describe what other tools do, not what they should do. No usability study was found or run.

## Rui baseline

The released installer's tail (local copy of the release template, lines 94–107) prints the following lines unconditionally:

- the `Installed … at …` line;
- `Previous builds, Stores and credentials were preserved.`;
- the `hash -r`/`rehash` hint;
- `Selected Store status (read only):`, followed by raw `rui host status` JSON;
- the "running Host keeps its old executable" line;
- `Start with: "$prefix/bin/rui"`.

Only the PATH lines (96–100) are conditional, and they compare `command -v rui` with `$prefix/bin/rui` as literal strings. The installer never reads an existing version before replacing it. `tests/ci/test_release.py:164,173` asserts the `Installed` and "running Host" strings, so wording changes must update that test. README step 1 after installing is `rui auth login codex` (`README.md:36-42`), not `rui`.

## Findings

### 1. First install versus upgrade

| Claim | Source and evidence |
| --- | --- |
| rustup treats an upgrade as a different command, not a rerun of the installer. Rerunning the installer on an existing install warns and stops unless the user confirms. | [rustup `self_update.rs` @2f3c4ea](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/self_update.rs#L656-L681): "It looks like you have an existing installation of Rust at:" … "You have already installed rustup: you can quit the installer right now." (L669–672). The module docs separate "During install (as `rustup-init`)" from "During upgrade (`rustup self update`)" (L9–21). |
| rustup's upgrade output states the outcome and the previous version. It distinguishes installed, updated and unchanged. | [rustup `common.rs` @2f3c4ea L161-L227](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/common.rs#L161-L227): the banners are `"installed"`, `"updated"` and `"unchanged"`. The format is `{pkg} {banner} - {version}`, plus ` (from {previous_version})` when the version changed. |
| rustup's first-install message is shown only on first install. It says what changed and where. | [rustup `msg.rs` @2f3c4ea L73-L107](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/self_update/msg.rs#L73-L107): "Rust is installed now. Great!" and "To get started you may need to restart your current shell." |
| rustup warns before the install when existing settings will change the result. This is the closest precedent for warning about existing saved state. | [`self_update.rs` L683-L705](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/self_update.rs#L683-L705): "it looks like you have an existing rustup settings file at:". |
| nvm detects an existing install by its directory and says so before updating. Its closing instructions are the same in both cases. | [nvm `install.sh` v0.40.8](https://github.com/nvm-sh/nvm/blob/v0.40.8/install.sh): "=> nvm is already installed in $INSTALL_DIR, trying to update using git" (L171, also L271). L513 "=> Close and reopen your terminal to start using nvm…" prints on every run. |
| mise reads the version of the binary already at the install path before downloading. It keeps a newer version and can skip the same version. | [mise `install.envsubst` v2026.10.24](https://github.com/jdx/mise/blob/v2026.10.24/packaging/standalone/install.envsubst): `installed_mise_version` runs `"$bin" version` (L301–306). "mise: $install_path is already at $existing_version, keeping installed version" (L372). With `MISE_INSTALL_SKIP_IF_EXISTS`, it prints "already at version $version, skipping install" (L386). The activation help in `after_finish_help` (L453–476) still prints on every run unless `MISE_INSTALL_HELP=0` (L480). |
| Volta reads the existing binary's version and treats reinstalling the same version as a no-op. | [Volta `volta-install.sh` v2.0.2](https://github.com/volta-cli/volta/blob/v2.0.2/dev/unix/volta-install.sh#L110-L118): "Version $will_install_version already installed". A comment adds "in the future, check $prev_version for incompatible upgrades" (L118). |
| Many respected installers print the same success text whether or not the tool was already installed. | Deno, Bun, flyctl, Starship and uv have no existing-install branch (see the [Comparison](#comparison)). [Starship's usage text](https://github.com/starship/starship/blob/v1.27.0/install/install.sh#L156-L160) says "if starship is already installed it will be updated", yet it prints "Please follow the steps for your shell to complete the installation:" (L552) on every run. [Volta setup](https://github.com/volta-cli/volta/blob/v2.0.2/src/command/setup.rs#L20-L22) always prints "Setup complete. Open a new terminal to start using Volta!", even when it skipped profile edits. |

### 2. PATH handling

| Claim | Source and evidence |
| --- | --- |
| clig.dev requires consent and an exact statement before a tool edits another program's configuration. | [clig.dev source @697d6a2, Configuration L1091-L1093](https://github.com/cli-guidelines/cli-guidelines/blob/697d6a29fc8c93d3981a755c0c7683507ad39c3e/content/_index.md?plain=1#L1091-L1093): "If you automatically modify configuration that is not your program's, ask the user for consent and tell them exactly what you're doing." It prefers a new file over appending to an existing one. |
| Homebrew never edits profiles. It detects a missing PATH entry, warns, and prints the exact commands. When the profile line already exists, it prints only the command for the current shell. When `brew` resolves, it prints nothing about PATH. | [Homebrew `install.sh` @8c82c08](https://github.com/Homebrew/install/blob/8c82c081753d4263da0cfe615ef8d9433425f22b/install.sh): L1092 checks `":${PATH}:" != *":${HOMEBREW_PREFIX}/bin:"*`. L1101 warns "… is not in your PATH." L1167–1182 handle the case where the rc file already has the `shellenv` line, and also check `command -v brew`. |
| Deno also never edits profiles. It prints manual instructions only when `command -v deno` fails. | [deno_install `install.sh` v0.1.9 L46-L58](https://github.com/denoland/deno_install/blob/v0.1.9/install.sh#L46-L58). |
| rustup edits profiles by default. It shows every file it will change and asks first, offers `--no-modify-path`, and does not append the same line twice. Its sourced `env` file guards against duplicate PATH entries. | [`msg.rs` L43-L52](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/self_update/msg.rs#L43-L52): "This path will then be added to your `PATH` environment variable by modifying the profile file{plural} located at:". [`unix.rs` L73-L74](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/self_update/unix.rs#L73-L74): `contents.contains(&source_cmd) => continue`. [`env.sh`](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/src/cli/self_update/env.sh) uses `case ":${PATH}:" in *:"{cargo_bin}":*)`. |
| uv (cargo-dist) edits several rc files without asking. It skips all edits when the install directory is already on PATH, and prints the reload instruction only when it changed a file. It also warns when another command shadows the installed one. | [uv-installer.sh 0.13.6](https://github.com/astral-sh/uv/releases/download/0.13.6/uv-installer.sh) (template: [cargo-dist v0.33.1](https://github.com/axodotdev/cargo-dist/blob/v0.33.1/cargo-dist/templates/installer/installer.sh.j2)). L1399–1403: "Avoid modifying the users PATH if they are managing their PATH manually". L1418–1425 print "To add … to your PATH, either restart your shell or run:" only after an edit. L1430: "The following commands are shadowed by other commands in your PATH:". The [uv docs](https://github.com/astral-sh/uv/blob/0.13.6/docs/reference/installer.md#L27-L37) document the `UV_NO_MODIFY_PATH` opt-out. |
| Literal string comparison of paths produces false "not on PATH" results, and those lead to unwanted profile edits. | [cargo-dist #2529](https://github.com/axodotdev/cargo-dist/issues/2529) (open, 2026-10-05): an un-normalized `…/../bin` "fails the pattern match … modifies the user's shell configuration files … even when the binary directory is already present". Local check (macOS `/bin/sh`): with `PATH=…/./a`, `command -v` returns `…/./a/ruix`, which a literal comparison with `…/a/ruix` would reject. |
| Choosing the right rc file is hard, and users report the failures. | [rustup #2106](https://github.com/rust-lang/rustup/issues/2106): the installer "adds a line to modify `PATH` in `~/.profile`. That file is not used at all in graphical terminals". |
| Bun edits the rc file without asking. When the command already resolves, it prints one line and exits. | [Bun `install.sh` bun-v1.4.4](https://github.com/oven-sh/bun/blob/bun-v1.4.4/src/runtime/cli/install.sh): L175–180 `if command -v bun …; then … echo "Run 'bun --help' to get started"; exit`. Otherwise L240–248 append to `~/.zshrc` and print "Added … to $PATH in …". |
| flyctl asks only when stdout is a terminal. Non-interactive runs print instructions and never edit. It also detects an existing profile entry. | [fly.io/install.sh](https://fly.io/install.sh), SHA-256 `a031272948eaca6c064a0756e4f43b0b3ee687716eeed2ab858fe0bdb0f029f5`: L124 greps the config file, L126 prints "flyctl PATH is already configured in …", L137–143 prompt "Would you like to add it automatically? (Y/n)", and `--setup-path` (L18–19) opts in. |
| fnm appends to the profile on every run, with no duplicate check. This is a counterexample. | [fnm `.ci/install.sh` v1.39.0 L169-L223](https://github.com/Schniz/fnm/blob/v1.39.0/.ci/install.sh#L169-L223): unconditional `>>"$CONF_FILE"`. Only `--skip-shell` avoids it. |
| `~/.local/bin` is the specified location for per-user commands. Debian and Ubuntu add it to PATH only if it **exists at login**, so on a first install the current shell does not have it, but the next login shell will. macOS does not add it at all. | [systemd `file-hierarchy(7)` v258](https://github.com/systemd/systemd/blob/v258/man/file-hierarchy.xml#L452-L459): "Executables that shall appear in the user's `$PATH` search path." [Debian bash `skel.profile` @db283bf L24-L27](https://salsa.debian.org/debian/bash/-/blob/db283bfd177f12da96dcb251e74d8d9a059336da/debian/skel.profile#L24-L27): `if [ -d "$HOME/.local/bin" ] ; then PATH="$HOME/.local/bin:$PATH"`. |
| Vendor docs describe the restart-the-shell step in prose rather than giving an unconditional `export` line. | [rustup book, Installation @2f3c4ea](https://github.com/rust-lang/rustup/blob/2f3c4eaec1a44edbe811ac39656770410c3a7ef0/doc/user-guide/src/installation/index.md#L11-L16): "Open a _new_ shell and type the following: `rustc --version`". |

### 3. Verbosity, version, location and next step

| Claim | Source and evidence |
| --- | --- |
| Success output should be brief, and a state change should be stated. | [clig.dev L561-L572](https://github.com/cli-guidelines/cli-guidelines/blob/697d6a29fc8c93d3981a755c0c7683507ad39c3e/content/_index.md?plain=1#L561-L572): "Display output on success, but keep it brief." … "it's usually best to err on the side of less." "If you change state, tell the user … so the user can model the state of the system in their head." |
| Suggest the next command. | [clig.dev L606-L608](https://github.com/cli-guidelines/cli-guidelines/blob/697d6a29fc8c93d3981a755c0c7683507ad39c3e/content/_index.md?plain=1#L606-L608): "Suggest commands the user should run." |
| Nearly every installer prints the install location, and most print the version. | Deno L46 "Deno was installed successfully to $exe". Bun L173 "bun was installed successfully to ~/.bun/bin/bun". flyctl L81 "flyctl was installed successfully to $exe". mise L450 "installed successfully to $install_path". uv L1346 "installing to $_install_dir" (version at L493). Starship L549 "Starship ${VERSION} installed". rustup prints the version on update. |
| When the command is on PATH, the shortest installers print one success line and one bare-name next step. They print the full path only when the name would not resolve. | Deno L47–57: bare `deno --help` when `command -v deno` succeeds, otherwise `'$exe --help'`. Bun L175–179 and flyctl L82–83 do the same. mise L474 prints the full path in its fallback case. |
| The next step can be the tool's real first action, not `--help`. | [Tailscale `installer.sh` v1.104.4 L731-L736](https://github.com/tailscale/tailscale/blob/v1.104.4/scripts/installer.sh#L731-L736): "Installation complete! Log in to start using Tailscale by running:" followed by `tailscale up`. Homebrew gives a few "Next steps" bullets ending in "Run brew help to get started" (L1137–1241). mise's next step is `mise doctor` (L459) to check the setup. |
| uv names no next command; "everything's installed!" is its final line unless PATH needs attention. | uv-installer.sh L1397. |
| Quiet modes exist for scripted installs. | uv's `UV_PRINT_QUIET` and `say()` (L46–50, L2004–2008). mise's `MISE_QUIET` and `MISE_INSTALL_HELP=0`. Volta's `--skip-setup`. |

### 4. Machine-readable output and internal terms

| Claim | Source and evidence |
| --- | --- |
| Human-readable output comes first. JSON belongs behind an explicit flag. | [clig.dev L531-L558](https://github.com/cli-guidelines/cli-guidelines/blob/697d6a29fc8c93d3981a755c0c7683507ad39c3e/content/_index.md?plain=1#L531-L558): "Human-readable output is paramount. Humans come first, machines second." and "Display output as formatted JSON if `--json` is passed." |
| Output meant only for the developers should not appear by default. | [clig.dev L677-L686](https://github.com/cli-guidelines/cli-guidelines/blob/697d6a29fc8c93d3981a755c0c7683507ad39c3e/content/_index.md?plain=1#L677-L686): "By default, don't output information that's only understandable by the creators of the software." and "Don't treat stderr like a log file". |
| No inspected installer prints raw JSON or runs a status command. When they report state, they translate it into a sentence. | rustup prints "rustup updated - X (from Y)". Volta prints "Version … already installed". flyctl prints "flyctl PATH is already configured in …". cargo-dist writes an install receipt as JSON to a file (uv L571–577) but never prints it. |
| A state check can still belong in an installer when it changes what the user must do. | [clig.dev L588-L604](https://github.com/cli-guidelines/cli-guidelines/blob/697d6a29fc8c93d3981a755c0c7683507ad39c3e/content/_index.md?plain=1#L588-L604): "Make it easy to see the current state of the system." rustup's settings-file warning and nvm's global-modules warning (`nvm_check_global_modules`, L381–397) report existing local state, but only when it is present. |

### 5. `hash -r` and `rehash`

| Claim | Source and evidence |
| --- | --- |
| Bash remembers a command's full path after the first PATH search, and assigning to `PATH` clears that table. A newly installed command that was never found before is located by an ordinary search. | [GNU Bash manual 5.3, Command Search](https://www.gnu.org/software/bash/manual/bash.html#Command-Search-and-Execution): "Bash performs a full search of the directories in `$PATH` only if the command is not found in the hash table." [`hash` builtin](https://www.gnu.org/software/bash/manual/bash.html#index-hash): "The `-r` option causes the shell to forget all remembered locations. Assigning to the `PATH` variable also clears all hashed filenames." |
| Zsh hashes a command's location on first execution. | [Zsh 5.9.2 options, `HASH_CMDS`](https://zsh.sourceforge.io/Doc/Release/Options.html#index-HASH_005fCMDS): "Note the location of each command the first time it is executed. Subsequent invocations of the same command will use the saved location, avoiding a path search." |
| None of the inspected installers mentions `hash -r` or `rehash`. They say "restart your shell", "open a new terminal", `source <rc>` or `exec $SHELL`. | rustup `msg.rs` L77; uv L1421; nvm L513; Bun L250 `exec $SHELL`; flyctl L131; Volta setup L21. |
| **Local experiment** (`/bin/bash` 3.2.57 and `/bin/zsh` 5.9, macOS 15). (a) Replacing the symlink at the same path, as Rui's upgrade does, runs the new build at once in both shells, with no rehash. (b) A first install of a command never found before also resolves at once. (c) A rehash is needed only when the shell had already run a **different** same-named command from a later PATH directory and the new one lands earlier on PATH. | To reproduce, run a script in each shell that sets `PATH="$PWD/a:$PWD/b:/usr/bin:/bin"`, runs `ruix` from `b`, links a different `ruix` into `a`, runs `ruix` again, then `hash -r` (Bash) or `rehash` (Zsh), then runs it a third time; finally it replaces `a/ruix` by `ln -s` and `mv -f` and runs it again. In case (c), both shells kept printing `old-elsewhere` until `hash -r`/`rehash`. A rerun on 2026-10-31 in the same shells gave the same result for (a) and (c). |

## Comparison

"Detects existing" means the installer reads the installed version or directory before replacing it. "Next step" is the printed command when the tool is already on PATH.

| Installer (pinned) | Detects existing install | Differs on upgrade | PATH strategy | Already on PATH | Prints version / location | Next step |
| --- | --- | --- | --- | --- | --- | --- |
| rustup 2f3c4ea | Yes: rustc/cargo on PATH and settings file | Upgrade is a separate command, `rustup self update`, which prints updated, unchanged or "from" | Edits rc files after showing them and asking; `--no-modify-path` | Duplicate-safe `env` file | Location before install; version on update | Restart the shell; `source …/env` |
| uv / cargo-dist 0.13.6 | No (writes a receipt for `uv self update`) | No | Edits several rc files without a prompt; `UV_NO_MODIFY_PATH` | Skips edits and prints nothing about PATH; warns on shadowed commands | Version while downloading; location | None |
| Deno v0.1.9 | No | No | Prints instructions only | One line | Location | `deno --help` (full path if not on PATH) |
| Bun v1.4.4 | No | No | Edits the rc file without a prompt | One line, then exits | Location (shown with `~`) | `bun --help`, after `exec $SHELL` if edited |
| Homebrew 8c82c08 | No (upgrade via `brew update`) | No | Prints commands only | Omits the PATH step | Lists paths before install | `brew help` and docs link |
| nvm v0.40.8 | Yes: install directory | Says "already installed … trying to update" | Appends to profile; skips if present; `PROFILE=/dev/null` | Same closing text | Version and directory | Reopen terminal or `source` |
| fnm v1.39.0 | No | No | Appends on every run, no duplicate check | Duplicates the line | Location | `source <rc>` |
| mise v2026.10.24 | Yes: version at install path | Keeps a newer version; optional skip for the same version | Prints instructions only | Still prints activation help | Selected version; location | `mise doctor` (full path in fallback) |
| Starship v1.27.0 | No | No | Prints init instructions on every run | Warns only if the bin directory is missing from PATH | Version, platform and location | Shell init lines |
| Volta v2.0.2 | Yes: version | The same version is a no-op | `volta setup` rewrites profiles idempotently | Skips edits, still says "Open a new terminal" | Version | Open a new terminal |
| flyctl (served script) | Profile entry only | No | Prompts on a terminal; `--setup-path`; otherwise instructions | One line | Location | `flyctl --help` |
| Tailscale v1.104.4 | Package manager | No | Not applicable (system package) | Not applicable | Package trace | `tailscale up` (log in) |

## Implications for Rui

Each item cites the findings above. **[Judgment]** marks a recommendation that no source states directly. You have said the accepted contract may change, so items 4 and 5 propose rewriting `ARCHITECTURE.md:581` rather than working around it.

1. **Read the existing version before replacing it, and branch on the result.** Run `"$prefix/bin/rui" --version` when the path exists, as mise (L301–306) and Volta (L110–116) do.
   - First install: print one line, `Installed rui 0.37.5 at ~/.local/bin/rui.`
   - Upgrade: print `Updated rui 0.37.4 → 0.37.5 at ~/.local/bin/rui.`, following rustup's "updated - X (from Y)".
   - Same version: say it is reinstalled, or follow Volta's no-op.
   - **[Judgment]** Keep the short commit hash only in `rui --version`, not in the success line. Use a `~`-relative path, as Bun does.

2. **Print "Previous builds, saved work and sign-in were kept" only on upgrade.** nvm, mise and Volta announce an existing install, and clig.dev L570 says to tell the user what changed. On a first install there is nothing to preserve. **[Judgment]** Use the README's terms ("saved work", "sign-in") rather than "Stores and credentials".

3. **On upgrade, warn when the Store format changes.** The middle version number is the Store format (`README.md:30`, `ARCHITECTURE.md:583`). When the old and new `S` differ, print one line: existing saved work needs a [fresh Store](../docs/store-reset.md) or the previous build. This is the single upgrade fact that changes what the user must do, which is the same purpose as rustup's settings-file warning (L683–705) and the incompatible-upgrade check Volta plans (L118). **[Judgment]** No other line needs the word "Store".

4. **Drop the raw JSON and the "Selected Store status" heading. Keep the Host line only when a Host is actually running.** Neither clig.dev (L531, L677) nor any inspected installer prints raw machine output. Run `rui host status` quietly and inspect its `status` field.
   - `unavailable` (always the case on a first install): print nothing.
   - `ready`: print `A Rui background process is still running the old version. When its work finishes, run: rui host stop`.
   - Incompatible or access failure: print one plain sentence.

   **[Judgment]** Change `ARCHITECTURE.md:581` from "the installer reports Host status" to "the installer reports a running Host and a Store-format change". A human rendering of `rui host status` would make the parsing unnecessary, but that change is out of scope here.

5. **Print the `hash -r`/`rehash` line only when another `rui` exists on PATH.** Rui's same-path symlink upgrade never needs it (local experiment, case a), and a first install never needs it either (case b). Staleness needs a different `rui` earlier in the user's shell history (case c). The installer can detect that case by scanning `$PATH` for another `rui`, as uv's shadowed-command check does (L1434–1447). In that case, print the resolved path and the remedy, or advise opening a new terminal, the wording every inspected installer uses. **[Judgment]** That also covers the existing "Your PATH currently selects …" case, so the two lines can merge.

6. **Make "Start with" conditional on whether `rui` resolves to the new install.** When it does, print `rui` (Deno L47–48, Bun L175–179, flyctl L82–83). When it does not, print the full path or the PATH fix (Deno L57, mise L474).
   - This contradicts the stated problem in part: printing the full path is the right fallback, not wrong in itself.
   - **[Judgment]** Name the real first step, as Tailscale does with `tailscale up` (L731): `Next: rui auth login codex` (`README.md:42`), or bare `rui`, whose chooser can start the same login (`ARCHITECTURE.md:969`). Because device-code authorization must be enabled in ChatGPT first, a one-line README link may help more than a bare command.
   - On upgrade, omit the next step or say `Run rui to continue.` **[Judgment]**

7. **Keep printing PATH instructions, not editing profiles.** Homebrew, Deno and mise never edit profiles. clig.dev L1091 requires consent for edits. rustup #2106, cargo-dist #2529 and fnm's unconditional append show what goes wrong. Two refinements:
   - Compare paths with `[ "$resolved" -ef "$prefix/bin/rui" ]` rather than as literal strings (cargo-dist #2529; local `…/./a` result). **[Judgment]** `-ef` is not in POSIX `test`, but dash, bash, zsh and BusyBox support it. Verify it under dash, the Ubuntu target, before relying on it.
   - On Linux, a first install creates `~/.local/bin`, so the next login shell will put it on PATH (Debian `skel.profile` L24–27). Lead with "open a new terminal", then offer the `export` line for the current shell.

8. **Make the README's PATH line conditional.** The README cannot detect anything, so it should describe the condition, as the rustup book does. The current unconditional `export` line followed by "add it to your profile if …" reads backwards. **[Judgment]** Suggested wording: "If the installer says `~/.local/bin` is not on your PATH, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile and open a new terminal." This partly contradicts the stated problem: the installer and README differ by necessity. The fix is wording, not removing the README line, because macOS never puts `~/.local/bin` on PATH.

9. **Keep the progress lines.** "Downloading Rui 0.37.5 for darwin-arm64 …" and "Checking the downloaded command …" match uv (L493) and clig.dev's advice that silent waits look hung (L563–564). **[Judgment]** Consider an opt-in quiet mode (`RUI_INSTALL_QUIET=1`) for CI, like uv's `UV_PRINT_QUIET`.

### Resulting output (illustrative, judgment)

First install, `rui` on PATH:

```text
Downloading Rui 0.37.5 for darwin-arm64 ...
Checking the downloaded command ...
Installed rui 0.37.5 at ~/.local/bin/rui.
Next: rui auth login codex
```

Upgrade with a running Host:

```text
Downloading Rui 0.37.5 for darwin-arm64 ...
Checking the downloaded command ...
Updated rui 0.37.4 → 0.37.5 at ~/.local/bin/rui. Previous builds, saved work and sign-in were kept.
A Rui background process is still running 0.37.4. When its work finishes, run: rui host stop
```

### Findings that cut against the stated problem list

- **Same text for install and upgrade is common practice.** Deno, Bun, uv, Starship, flyctl and Tailscale do it, and nvm, Volta and mise repeat their closing help on upgrade. rustup, mise and Volta support differentiating, but it is not a consensus. The case for it here rests on Rui's own upgrade-only facts: preservation, Store format and a running Host.
- **The full path in "Start with" is the correct fallback** when the name does not resolve (Deno, mise). It is wrong only when `rui` is on PATH.
- **`hash -r` is not an upgrade-only line.** Rui's same-path upgrade never needs it. It is needed only when a different `rui` was already found elsewhere.
- **"Store" is not purely internal.** The README's install section already uses it (`README.md:30`). The problem is printing it on a first install, before it means anything, not the term itself.
- **The README's PATH line cannot simply match the installer.** The README cannot detect PATH, and `~/.local/bin` is missing from PATH on macOS by default and in the current shell on a Debian or Ubuntu first install.
- **Reporting Host status was an accepted contract** (`ARCHITECTURE.md:581`). Removing it is a contract change, not just a wording fix.
