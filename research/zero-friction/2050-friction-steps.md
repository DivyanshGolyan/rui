# #2050 Every step to the first useful answer in Rui, timed

Researched 2026-11-23 against release **0.88.1** (what `https://ruicode.com/install` and npm `ruicode` serve today) and current `main` (checkout HEAD `5a6b6e52`). Builds on `/mnt/project-files/agent-preference/install-funnel.md` (2026-11-12).

Labels: **[measured]** run in this container (Ubuntu 24.04, x86-64, glibc 2.39, Node 22.23.5, fast datacenter network, fresh temp HOME); **[source]** read in Rui's code or docs (file named); **[guess]** an estimate, not measured. Drop-off rates are all guesses.

## Answer

The machine part of both paths is now near-instant: the curl install took 1.7 s and `npm install ruicode` 0.6 s, and `rui` shows its sign-in card at once. Everything slow and lossy is human: sign-in (30 s to 10 min, longest when you need an API key), and on the TS path, picking a model name and getting the README sample to run. Best case is about 2 to 4 minutes for the terminal with a ChatGPT plan, 5 to 15 minutes with an API key, and 5 to 15 minutes for the library. The worst TS leak is that the README sample **exits 0 and prints nothing** when the key is wrong or missing, and the TS guide's example fails outright on 0.88.1.

## (a) Terminal app

| # | Step | Time | Basis | Likely drop-off |
|---|---|---|---|---|
| 1 | Find the install line (README "Use it in your terminal", below the TS section) | 1–3 min | [guess] | 10–20%: the README leads with the library and a benchmark; terminal users scroll |
| 2 | Platform check (macOS 15+ Apple Silicon, Linux x86-64 glibc 2.34+) | — | [source] README.md, release/install.sh | 10–25% turned away (see list below) |
| 3 | `curl -fsSL https://ruicode.com/install \| sh` | **1.7 s** (script fetch 1.1 s) | [measured] | <2% on a supported machine |
| 4 | Get `rui` on PATH: installer edited `~/.bashrc`, says "Open a new terminal" | 5–30 s | [measured] output; time [guess] | 3–8%: the "Next: run rui" line prints *before* the "Added ~/.local/bin to your PATH… Open a new terminal" line, so some type `rui` in the same shell and get "command not found" |
| 5 | Run `rui` in a project folder: "Welcome to Rui — Sign in to begin" card, ChatGPT / API key / Close | **4 ms** to first output | [measured] PTY capture | ~1% |
| 6a | ChatGPT → **Browser (Recommended)**: link + Open browser, log in to ChatGPT, approve, callback (paste the final address if the browser cannot reach back) | 30–90 s | [guess] from docs/using-rui.md#sign-in and session-ui.md | 10–20%: no ChatGPT plan, or plan/workspace not allowed for Codex (eligibility of Free plans unknown); SSH users hit the paste-callback fallback |
| 6b | ChatGPT → Device code: copy code, approve in a browser | 1–3 min; +2–5 min if "device code authorization for Codex" is off in ChatGPT security settings | [source] src/cli.zig `device_login_guidance`; time [guess] | 20–40% of those who pick it: setting off by default, workspace admin may block. The TUI device page does not mention the setting (src/SignIn.zig row text); only `rui auth login chatgpt --device-code` prints guidance, with no direct link |
| 6c | API key: Base URL prefilled, paste key, Model ID ("Required for custom services"), Connect. "Key is not verified remotely" | 30 s with a key in hand; 3–10 min to create a key and add billing | [measured] form text; time [guess] | 20–35% of those without a key; a bad key is only found on the first request |
| 7 | First prompt: after sign-in a chat opens beside the overview with input focused (wide terminal); there is no suggested first task | 10–60 s | [source] docs/contracts/session-ui.md "Human entry"; time [guess] | 5–10% |
| 8 | Model answers | 5–30 s | [guess] | ~2% (quota, rate limit) |
| | **Total to first useful answer** | **~2–4 min** (ChatGPT browser); **5–15 min** (new API key) | | |

## (b) TypeScript library

| # | Step | Time | Basis | Likely drop-off |
|---|---|---|---|---|
| 1 | Read README "Start an agent from TypeScript" | 1–3 min | [guess] | 5–10% |
| 2 | Node 22.6+ and platform check | — | [source] package.json `engines >=22.6` | 5–15% (old Node, Windows, Intel Mac) |
| 3 | `npm install ruicode` (pulls `ruicode` 356 KB + `ruicode-linux-x64` 20 MB, same binary as curl) | **0.56 s**, empty npm cache | [measured] | <2% |
| 4 | Get `OPENAI_API_KEY` | 0–10 min | [guess] | 20–35% without a key. README sample is API-key only; ChatGPT sign-in for libraries is only in clients/ts/README.md (`providers: { chatgpt: {} }` after `rui auth login chatgpt`) |
| 5 | Choose `RUI_MODEL`: README gives no value; the guide says "a model your provider offers that accepts `low` reasoning effort" | 1–5 min | [source] README.md, docs/integrating-rui.md; time [guess] | 10–15% |
| 6 | Save and run the sample. README gives no file name or run command; the code is TypeScript (`!`). `npm init` makes a CommonJS package, so Node warns `MODULE_TYPELESS_PACKAGE_JSON`; on Node 22.6–22.17 a `.ts` file needs `--experimental-strip-types` (on by default from 22.18) | 1–5 min | [measured] warning on 22.23.5; Node-version flag from Node release notes [source, not run] | 10–20% |
| 7 | Rui.connect + create + send | **1.1–1.4 s** to a failure or admission | [measured] with dummy/missing key | see failure modes |
| 8 | Model answers, printed by the loop | 5–30 s | [guess] | — |
| | **Total** | **~5–15 min** (with a key and model in mind ~3 min) | | |

Failure modes **[measured]** with the README sample on 0.88.1:

- No `RUI_MODEL`: `RuiRequestError: Rui rejected the request: MissingField`, exit 1. It does not say which field.
- `RUI_MODEL` set, no key: stderr `provider output rejected for operation 1: UnsupportedCallControl`, **exit 0, no answer**. (The container's proxy may shape this code; not checked elsewhere.)
- Wrong key: stderr only `OpenAI model list unavailable (ListingRefused)`, **exit 0, no answer**. The feed has `turn_ended` with `ending: provider_refused, code: provider_api_key_rejected`, but the README loop breaks without printing it.
- docs/integrating-rui.md example, run exactly as written (`node --experimental-strip-types example.mts`): `incomplete_initial_configuration`, exit 1, because it omits `workspace`. Adding `workspace: process.cwd()` makes it reach the provider and report `provider_api_key_rejected` correctly. On `main`, `src/caller_error.zig` still requires "a Workspace for standalone creation" [source], so the guide is wrong on main too [inferred].
- The TS client surfaces only the code; the Host's plain sentence ("A new Session's spec is missing a required setting… Supply the missing model, Workspace or provider", src/caller_error.zig) does not reach the user [measured: message absent; source text read].

## Who is turned away entirely

| Who | Terminal (curl) | Library (npm) | Basis |
|---|---|---|---|
| Intel Mac | Refused: "Supported platforms: macOS Apple Silicon and Linux x86-64." | Installs, but no platform package; client falls back to `rui` on PATH and spawn fails | [source] release/install.sh; dist/binary.js |
| macOS 14 or older on Apple Silicon | README says 15+; installer does not check | same | [source] README.md |
| Windows native | No `sh`; nothing runs | Installs, no win32 package, spawn fails. WSL2 x86-64 works [inferred] | [source] dist/binary.js |
| Linux arm64 | Refused by installer | **Supported** (experimental `ruicode-linux-arm64`) | [source] release/install.sh, docs/integrating-rui.md |
| glibc < 2.34 (Ubuntu 20.04, Debian 11, RHEL/Alma 8, Amazon Linux 2) and musl/Alpine | Binary needs `GLIBC_2.34` (dynamically linked); the installer's `rui --version` check would die with a loader error, not a plain sentence [inferred] | same binary | [measured] `objdump -T` max GLIBC_2.34, `cmp` npm == curl binary |
| No ChatGPT plan (or plan/workspace without Codex access) | API key route only | README path unaffected | [source] |
| No ChatGPT plan **and** no API key | Turned away | Turned away | [source] |
| No API key (has ChatGPT) | Fine | README sample unusable; must find `providers: { chatgpt: {} }` in clients/ts/README.md and run `rui auth login chatgpt` from a separately installed CLI | [source] |
| Node < 22.6 | — | npm only warns on `engines` (EBADENGINE) [inferred, not run]; the TS sample then fails to run | [source] package.json |

## Changes since the install-funnel study (2026-11-12)

- **Browser sign-in is now in the terminal app and marked Recommended**, with device code second and "Use saved login" third [measured]. This moves most users off the device-code security setting the study called the biggest leak.
- The device-code refusal still names no direct settings link, and the TUI device page does not mention the setting [source].
- **PATH editing shipped** (`~/.bashrc` edited, `RUI_NO_MODIFY_PATH=1` opt-out) and **`$GITHUB_PATH` append shipped** [measured / source].
- **Not done:** "or run `exec $SHELL`" (still "Open a new terminal"); bolding; the "Next" line now carries a README link but prints before the PATH line [measured].
- **Not done:** suggested first prompt; after sign-in the user still faces an empty chat [source].
- Sign-in is a restyled "Welcome to Rui" card [measured].
- README now leads with the TypeScript library; the study covered the terminal only. The library supports Linux arm64, which the curl installer refuses.
- Release is 0.88.1.

## Not done / unverified

- No real sign-in or model answer: sign-in and answer times are guesses.
- Not run on macOS, arm64, old glibc, Windows or old Node; those rows are from source.
- Container network is a datacenter link; home downloads of the 20 MB binary will take longer (guess 2–10 s).
- Drop-off percentages are guesses; no telemetry exists (study's "free signals" not pulled).
