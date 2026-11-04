# Drift's review of #872: triage

Source: Drift agent's review against Drift `master` at f2fa370e96 (uploaded by Divyansh 2026-11-04 06:51Z).
Each finding gets one outcome: my technical call (a new D line in ledger.md), a question for Divyansh, or a fact correction.

## Technical calls (D177 to D190)

| # | Finding | Call |
| --- | --- | --- |
| 1 | Tools need the caller's identity (blocks the port) | D177. Every MCP `tools/call` carries the calling Session's id, its parent and its root in `_meta`. Arguments are unchanged (D62 still strips `rui_call_description`). This is context, not a call id, so D61 stands. |
| 3 | `sessions.create` with a `parent`; tags | D178. `sessions.create` accepts `parent` with the same rules as `start_agent` (inherit, only narrow). No tags: Drift keeps its ticket-to-Session mapping in its own database, keyed by Session id, so the fact lives in one place. |
| 4 | Usage and served model on the feed | D179. The feed gains a `model_call` entry per model call: model, served model, input, output and cached tokens, latency, time to first event, status. Replaces D73, because a reader now exists. Cost stays Drift's. |
| 5 | Signal when a whole tree is idle | D180. A child's `turn_ended` appears in every ancestor's feed with its `sessionId`, the same way approvals do (D135). |
| 6 | Host cap set at connect | D181. `activeCapacity` in the launch frame (today's `--active-capacity`). No priority in Rui: with D177, Drift's own handler gate can put a person's calls first. The "hold new Turns" pause is a question for Divyansh. |
| 7a | Large tool results | D182. An MCP result follows the same model-facing bound as Bash output; the full result is kept and read with `read_transcript(full)`, chunked. No spill files. |
| 7b | Lock during a rolling deploy | D183. `Rui.connect` retries `store_locked` until `lockWaitMs` (default 120 s), then fails with `RuiStartError store_locked`. |
| 8a | Serial write tools | D184. Within one reply, MCP tools without `readOnlyHint: true` run one at a time in reply order; read-only ones run at once. The hint only orders calls; it never makes a call safe to rerun (D61 stands). |
| 8b | `rui.shell` is not a sandbox | D185. The TS package starts Rui with only `PATH`, `HOME` and `TMPDIR`, so Drift's secrets are not in Rui's environment; the docs say `rui.shell` runs as the host's user and is not a sandbox. |
| 8c | linux-arm64 | D186. Add `rui-linux-arm64` to the release platforms. |
| 8d | One client per process | D187. TS docs: one `Rui.connect` per process; cache the client on `globalThis` in Next.js. |
| 16 | Prisma reason is wrong | D188. Drop D82's Prisma reason; the own-schema and restore-together reasons stand. D83 note: Drift's pool still carries every MCP tool call, and Drift bounds that itself. |
| 34 | `GET /v1/models` on Marlin unprobed | D189. Drift probes it before the port. If Marlin does not serve it, D80 is revisited then, not before. |
| 30 | #840 numbers | D190. Measured: 249.3 MiB idle, 282.1 (1 agent), 285.7 (8), 298.0 (9), 312.8 three minutes after release (Private_Dirty median). |

## Questions for Divyansh, one at a time

1. Item 2: what happens to a map's workers when the map root's context is full, or when Drift moves a map to a new model.
2. Item 6: whether Rui gets a "hold all new Turns" switch for Drift's operators.

## Facts taken as given (no Rui change)

- Drift keeps its own Bash (`just-bash`) as a Drift MCP tool and never lists `bash` (22).
- Drift adds an agent-only MCP endpoint with a static token (23), bounds its handlers' pool use (24), takes the stop cascade (25), closes the client early in shutdown (26), drops its `activity` argument, fallback key, effect receipts, session files and Anthropic rail (27).
- `callTimeoutMs` for Drift is at least 1,800,000 (18). Node is 22.23.4 (13). MySQL is 8.4.5 on stage (15). No Drift agent uses web search (19).
- Session keys: `map:<ticket>`, `wake:<map>:<first wake_intents id>`, Run id UUIDs (9).

## Build plan impact

- M3b gains D177, D182, D184. F2 gains D179 and D180. A2 gains D181. A3a gains D183 and D185. A4 gains D186. K1 gains D178.
- Question 1's answer may change K2 (stop cascade).
