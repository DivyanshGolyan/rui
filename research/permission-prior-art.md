# Permission ownership and disconnected clients: prior art

Inspected 2026-09-13 for [Choose permission policy ownership and disconnected-client behavior](https://github.com/DivyanshGolyan/latifa/issues/159). Four Luna researchers inspected one harness each; the parent checked source references and reconciled the findings. This is source evidence, not a Latifa decision or runtime qualification. Accepted behavior remains in [ARCHITECTURE.md](../ARCHITECTURE.md#model-output-tools-and-permission).

## Source revisions

Existing clean local clones were fetched and fast-forwarded. No upstream source was edited.

| Harness | Updated branch and commit | Release boundary |
| --- | --- | --- |
| Pi | `main`, `71dca871bc80b6bc97be37f0ca3189399d651fff` | `v0.85.1` checked for permission-path differences; none material found. |
| DeepSeek Harness | `master`, `c291e7961a515f6d7af9304e7fd1d257929aef26` | No published GitHub release was available. |
| OpenCode v2 | `v2`, `c5aa7d7e34a19af7b94f5937f905ab2bac58e4a7` | September 12 version sync for 2.0.3. The earlier `2.0` branch selection was wrong; its findings are superseded. |
| Codex CLI | `main`, `a592c38c16cdd7623dacc9168926ebccedfb67d3` | Research uses latest stable `rust-v0.154.0`, commit `6b9826e3aa83b1a5947db50f4332cb9c65f1b340`, with main differences identified separately. |

## Comparison

Each linked report contains owning source paths, pinned links and the limits of the inference.

| Harness | Policy and approval ownership | Grant lifetime | Client disconnect and process restart |
| --- | --- | --- | --- |
| [Pi](permission-prior-art-pi.md) | Stock tools execute with process authority. Optional extension hooks can ask the UI and block a tool. Project trust controls resource loading, not tool authority. | Tool-approval reuse is extension-defined. Saved directory trust is a different grant. | RPC UI waits live in a resolver map. Stdin EOF shuts down the process; this path provides no pending-approval reconnect or restart recovery. |
| [DeepSeek Harness](permission-prior-art-deepseek.md) | Host approval service reads Session policy; sandbox/executor enforces the execution boundary. Browser is an answerer. | Session permission knobs are logged and reused; ordinary action approval is one-shot. | Live Host gateway retains pending requests and re-delivers them to a replacement browser connection. Those live callbacks are not reconstructed from the Session log after Host death. |
| [OpenCode v2](permission-prior-art-opencode.md) | Permission service checks agent/Session deny rules first, then saved project grants and plugin evaluation. UI lists and answers requests. | Once, or SQLite-saved project/action/resource grants when “always” has save patterns. Saving re-evaluates pending requests across Sessions in the same location. | Pending requests and deferred tool execution remain resident. Saved grants survive restart; pending waits do not gain durability from that store. |
| [Codex CLI/app-server](permission-prior-art-codex.md) | Core owns policy and execution enforcement; UI returns a decision bound to the pending request. Sandbox scope and prompting policy are separate. | One-off approvals, turn/Session grants, and persisted policy amendments are distinct mechanisms. | Live app-server can replay pending thread requests after reconnect. Callback maps and waiting execution are process-local; this is not durable pending-action recovery after process death. |

## Concrete implications for the open decision

These are interpretations of the source evidence, not accepted changes:

- **Closing the UI need not own permission lifetime.** DeepSeek and Codex keep the request with the running Host and let another connection present it. Latifa can keep its stronger committed-request recovery without giving the UI authority over execution.
- **An advance policy and an exact approval are different facts.** A Session can retain policy across reuse while an approval authorizes one action. Codex additionally exposes narrower grants and saved rules; that breadth is precedent, not evidence Latifa needs the same machinery.
- **“Always” needs an explicit scope.** OpenCode demonstrates why: “always” can persist project-scoped matching grants and can also answer other pending requests. It differs from Latifa's current rule that changing `ask` to `bypass` does not answer existing requests.
- **Unattended does not mean auto-approve every request.** DeepSeek and Codex separate the execution boundary from whether interactive escalation is available. OpenCode v2 also has a client-local auto-approver that sends one-time replies and sweeps known pending work after reconnect; it is not server-side bypass. Pi relies on its extension/deployment policy.
- **None of these inspected approval paths establishes Latifa's durable, bounded wait guarantee.** A logged policy or conversation is not a saved exact request plus recoverable authorization and execution state. Source-only inspection also does not establish a memory bound or crash qualification.

The subsequent [user decision](https://github.com/DivyanshGolyan/latifa/issues/159#issuecomment-5651237684) retains core-owned per-Session policy, configured by Runtime and other clients through the ordinary API. The owning contract records that decision; this comparison preserves its source evidence.

## Reproduction and limits

Use the pinned revisions and linked owning files in each report. References were checked against local Git objects for source existence and line bounds, with key approval, disconnect and scope claims reread. No upstream tests, binaries, providers, sandbox experiments or crash tests were run. `git diff --check` checks these documentation edits only. No production source or accepted contract changed.
