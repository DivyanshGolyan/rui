# Ghostty lessons for the architecture repair

Research date: 2026-08-25
Ghostty revision: [`6a508fd5e34c7e222c052a6d00bb3891ff3feace`](https://github.com/ghostty-org/ghostty/tree/6a508fd5e34c7e222c052a6d00bb3891ff3feace)

> Historical design input: this pass assumed JavaScriptCore remained the production executor. The
> later native-Core decision supersedes that runtime-specific recommendation while preserving the
> lessons about semantic interfaces, fixed storage, generations, and prepared publication. See
> [`../spikes/0011-native-core-image.md`](../spikes/0011-native-core-image.md).

## Decision

Ghostty reinforces the proposed issue boundaries, with three important refinements:

1. The native Core prerequisite must be a **semantic translation module**, not a relocated table of JavaScriptCore function handles.
2. The Harness repair must define a mechanically no-fail publication phase and a closed distinction between rejectable input, a poisoned live owner, and reconstructable durable state.
3. Issue #13 should implement one bounded byte renderer, but it must not use a VT parser as a sanitizer or copy Ghostty's mutable-source approval retry.

Ghostty does **not** justify splitting semantic Session publication into another public seam. Its snapshot decoder is a deep internal codec with explicit phases; the terminal remains the product seam. OnePage should likewise keep physical Session codecs internal and test lifecycle semantics through `Harness.open / offer / drive`.

## 1. Make Native Core semantic, owned, and generated

At the reviewed historical revision, OnePage kept 29 raw Wasm function references, numeric state interpretation, JavaScriptCore mechanics, and a mutating compatibility probe inside `agent.zig` ([`src/agent.zig:68-240`](https://github.com/DivyanshGolyan/onepage/blob/8b3e214db611ab8a01d845c7669bfd216ecf6d9d/src/agent.zig#L68-L240)). The one-page policy core exposed many scalar getters ([`src/core.zig:80-323`](https://github.com/DivyanshGolyan/onepage/blob/8b3e214db611ab8a01d845c7669bfd216ecf6d9d/src/core.zig#L80-L323)). Moving that code unchanged into `core_native.zig` would have improved locality only cosmetically; the module would have remained shallow because every Harness caller still understood raw export names, offsets, and numeric states.

Ghostty's native wrapper owns the persistent I/O and parser state needed to make repeated calls safe ([`src/terminal/c/terminal.zig:42-121`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/terminal.zig#L42-L121)). Its public values distinguish opaque owned handles, borrowed slices, and caller-owned output buffers whose capacity failure is an ordinary result ([`include/ghostty/vt/types.h:87-276`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/types.h#L87-L276)). The wrapper maps internal errors into a small semantic result set rather than leaking Zig error details ([`src/terminal/c/paste.zig:37-90`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/paste.zig#L37-L90)).

Apply that shape to Native Core:

- Own the JavaScriptCore context, Wasm instance, exact one-page memory, cached raw exports, and their lifetime in one opaque module.
- Expose domain operations and fixed value snapshots such as submitted Operation identity, selected Model Context range, interpreted Action, Approval state, and Outcome. Do not expose raw function references, memory offsets, or a generic `value(export)` getter.
- Copy each semantic snapshot into caller-owned fixed storage before returning. If a window is borrowed, document that the next Core mutation invalidates it.
- Use closed errors: incompatible artifact, invalid domain transition, insufficient caller capacity, and failed runtime. Do not use `anyerror` across the seam.
- Keep `jsc_runtime` as private mechanism, not a second product interface or mock target.

Ghostty generates its ABI metadata from the actual types at compile time and validates the resulting manifest by executing both native and Wasm artifacts ([`src/terminal/c/types.zig:1-6,343-409`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/types.zig#L1-L6), [`src/terminal/c/types-schema-verify.py:22-102`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/types-schema-verify.py#L22-L102)). OnePage does not need a JSON manifest in its 64 KiB page, but it should generate host-side export names and numeric encodings from one declaration and export a tiny ABI version or fingerprint. The compatibility test must instantiate the actual compiled Wasm artifact through JavaScriptCore.

At the reviewed revision, the `Core.open` compatibility probe drove a full sequence of mutations on the instance that would later be used ([`src/agent.zig:158-240`](https://github.com/DivyanshGolyan/onepage/blob/8b3e214db611ab8a01d845c7669bfd216ecf6d9d/src/agent.zig#L158-L240)). The recommendation was to replace it with structural artifact verification plus a real-artifact integration test, or run behavioral conformance on a disposable instance. Opening a production Core must leave it in one documented initial state.

### Test consequences

- Test the semantic Native Core interface against the real compiled Wasm artifact and JavaScriptCore.
- Keep narrow artifact tests for one memory page, no growth, exact exports, and ABI fingerprint.
- Test capacity exhaustion as a normal result with caller-owned buffers. Ghostty's encoding interface reports required capacity rather than allocating invisibly ([`include/ghostty/vt/types.h:261-276`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/types.h#L261-L276)).
- Do not add a fake policy Core. The real one-page artifact is the test subject; deterministic adapters belong outside it.

## 2. Turn Harness transitions into prepare, commit, publish

Ghostty builds a page while it is detached, validates all dimensions and accounting, and only then links it into live state. Immediately before publication it marks later failure as compile-time unreachable ([`src/terminal/PageList.zig:4347-4463`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/PageList.zig#L4347-L4463)). A smaller replacement path follows the same rule: once preparation succeeds, no fallible work is allowed while references and live-list ownership change ([`src/terminal/PageList.zig:4326-4344`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/PageList.zig#L4326-L4344)).

At the reviewed revision, OnePage's generic `Transition` made `classify`, `persist`, and `apply` independently fallible ([`src/harness.zig:66-71`](https://github.com/DivyanshGolyan/onepage/blob/8b3e214db611ab8a01d845c7669bfd216ecf6d9d/src/harness.zig#L66-L71)). That permitted a durable fact to commit and then fail while applying its corresponding Core state. Marking the owner failed was necessary but did not make the transition contract clear or mechanically safe.

The Harness repair should instead define this internal shape:

```text
prepare in fixed scratch
  -> validate identity, generation, descriptor, capacity, and Core transition
  -> materialize exact journal/checkpoint/projection inputs
commit authoritative durable fact
publish prepared Core state and projection without allocation or validation
```

Durable I/O can still fail during `commit`. Nothing after successful commit should invent new semantic validation or allocate. If a platform mechanic prevents literally infallible Core publication, the operation must be idempotently reconstructable from the committed fact and the current in-memory owner must become unavailable.

This rule belongs in the single Harness corrective issue because it spans Model Operation, Attempt, Action, Approval, Conversation Entry, checkpoint, and Projection ordering. Extracting a public Session coordinator would move the same lifecycle complexity rather than concentrate it; it fails the deletion test.

## 3. Specify reusable-versus-poisoned owner states

Ghostty's snapshot decoder distinguishes failures by whether source consumption crossed its point of no return. Invalid arguments detected before consumption leave the decoder reusable; decoding, I/O, or allocation failures after consumption poison it. A terminal already published at `READY` remains caller-owned and usable even if later history restoration fails ([`include/ghostty/vt/snapshot.h:423-477`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/snapshot.h#L423-L477)). Its record stream also uses strict order, independent checksums, and explicit `READY` and `FINISH` completeness markers ([`include/ghostty/vt/snapshot.h:23-113`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/snapshot.h#L23-L113)).

OnePage needs the analogous contract:

- A rejected or full `offer`, invalid precondition, or failed preparation leaves the current Harness owner usable and transfers no ownership.
- A failure after an authoritative journal publication makes the current in-memory owner unavailable. The durable Session remains recoverable through a fresh `open` unless corruption prevents it.
- Corruption, impossible ordering, or a record whose committed meaning cannot be reconstructed fails the Session closed.
- Ordinary waiting, Approval required, denied Action, indeterminate Attempt, and adapter failure are durable states/results, not `drive` errors.

Represent these categories with closed result/error sets. Do not let storage, Core, JavaScriptCore, or adapter `anyerror` escape without classification.

Ghostty's `READY` split is an anti-lesson for Session recovery. Missing old scrollback is inert, so Ghostty can safely expose a terminal early. An unreconciled OnePage Attempt is consequential. `Harness.open` must not dispatch, accept permission, or emit a misleading committed Projection until journal-ahead-of-checkpoint reconciliation reaches a safe watermark.

### Test consequences

Add tests proving that every injected failure is classified into exactly one of:

1. rejected with the same live owner still usable;
2. owner unavailable but fresh `open` reconstructs and advances once;
3. durable Session corruption that fails closed.

Run those assertions at every semantic publication boundary, not every filesystem call. Keep physical record CRC, truncation, ordering, atomic rename, and sync mechanics in narrow Session codec tests; keep their lifecycle meaning at the Harness seam.

## 4. Attach generations to owners and make stale references inert

Ghostty tracked references store both their owning terminal/screen identity and that screen's generation, validate it before dereference, and degrade to `NO_VALUE` after reset or owner destruction rather than aliasing recycled storage ([`src/terminal/c/grid_ref_tracked.zig:16-31,127-228`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/grid_ref_tracked.zig#L16-L31)). Rebinding allocates and validates the replacement pin before releasing the old one, so allocation failure preserves the original reference ([`src/terminal/c/grid_ref_tracked.zig:73-91`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/grid_ref_tracked.zig#L73-L91)).

Preserve the proposed OnePage identities, but make their ownership explicit in every internal handle:

- Core windows name the Core generation that owns their memory.
- Completion names Session ownership epoch, Agent generation, Operation, and Attempt.
- Projection slices are borrowed only until the next `drive`.
- A stale handle remains safe to release or classify but can never mutate a recycled execution page.
- A matching late completion from an older ownership epoch is accepted only by resolving it against a currently open durable Attempt; generation alone is necessary but not sufficient evidence.

Test stale values after page reuse, Core reconstruction, Session reopen, duplicate completion, and wrap/rejection limits. This belongs in Native Core and Harness tests, not in callers.

## 5. Keep `offer / drive`; do not copy Ghostty's mailbox failure policy

Ghostty requires PTY mutation to occur on its mailbox thread ([`src/termio/Termio.zig:422-435`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Termio.zig#L422-L435)), which supports OnePage's single-owner `drive` rule. Its queue is fixed at 64 messages, but a full queue may wait forever and wake failures may drop messages ([`src/termio/mailbox.zig:11-16,57-108`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/mailbox.zig#L11-L16)). Those policies are appropriate compromises for UI traffic, not for accepted durable operations.

Keep OnePage's stronger contract:

- `offer` does no I/O, allocation, wait, or Core call.
- `full` and `busy` leave ownership with the producer.
- Accepted Completion and permission facts are never dropped or coalesced.
- `drive` alone mutates Core state or admits an Attempt to an adapter.
- A configured quantum bounds one activation; do not drain forever as Ghostty's UI loop does.

This supports the existing Harness issue boundary. It does not justify a scheduler, thread abstraction, or second queue module in V1.

## 6. Approval must bind immutable bytes, unlike Ghostty paste retry

Ghostty's unsafe paste protocol has a valuable transaction property: rejection writes nothing, so the caller can ask and retry ([`include/ghostty/vt/paste.h:45-53,167-185`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/paste.h#L45-L53)). But its retry deliberately rereads the clipboard, and the confirmed bytes may differ from those originally rejected ([`include/ghostty/vt/paste.h:49-53`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/paste.h#L49-L53)).

Do not copy that aspect. For OnePage:

- Validation produces one immutable durable Action descriptor and digest.
- `approval_required` identifies that exact descriptor and renders those exact bytes.
- `Harness.offer(permission)` carries the same identity, generation, and digest.
- An allowed decision admits an Attempt over the already-durable descriptor; it never rereads or redecodes mutable model or workspace bytes.
- A mismatch is stale input, not a reason to ask the adapter what should run.

Ghostty also defaults side-effecting VT callbacks off and forbids synchronous reentry during parsing ([`include/ghostty/vt/terminal.h:55-83`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/terminal.h#L55-L83)). Likewise, Core interpretation must remain pure: only Harness may turn a committed Action into adapter admission.

## 7. Issue #13 needs a byte renderer, not terminal emulation

Ghostty's VT write path intentionally interprets raw ESC, CSI, OSC, and other controls. It is robust against malformed untrusted input, but it is not a sanitizer: the bytes still change terminal state, and configured effects can ring the bell, change the title, access clipboard protocols, or produce replies ([`include/ghostty/vt/terminal.h:55-102,1946-1969`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/terminal.h#L55-L102)). Running model or subprocess bytes through `libghostty-vt` and then writing the original stream would not make OnePage output safe.

Amend issue #13 to require one bounded terminal adapter with two lanes:

- **Trusted framing:** fixed OnePage-authored ASCII and optional fixed SGR constants.
- **Untrusted body:** a lossless, byte-wise display encoding read from durable blobs through fixed windows. Preserve intentional line boundaries; escape every other control and ambiguous byte. Never preserve attacker-provided SGR, OSC, hyperlinks, cursor movement, carriage return, tab, bidi controls, or zero-width formatting as active terminal syntax.

A byte-wise encoding such as printable ASCII plus `\\xNN` is deliberately simpler than VT parsing and carries no state across windows. Ghostty's bounded capture code is good precedent for making the actual allocation respect the configured bound rather than merely checking logical length ([`src/terminal/osc.zig:306-322,518-535`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/osc.zig#L306-L322)).

Do not use Ghostty's `stackFallback` pattern, which keeps a small stack fast path but silently falls back to an allocator ([`src/terminal/c/paste.zig:61-67`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/paste.zig#L61-L67)). OnePage's measured modules must return a capacity/spill outcome rather than escape the memory budget.

### Test consequences

- Keep the real CLI with captured stdin/stdout/stderr as the product seam.
- Feed every hostile byte sequence at every fixed-window split point and assert that only trusted renderer constants can produce control bytes.
- Include incomplete ESC/UTF-8 sequences, CSI erase/cursor movement, OSC title/hyperlink/clipboard, DCS/APC/PM, carriage return, backspace, tabs, bidi/zero-width code points, fake `Session:`/`Allow?`/`Final Answer:` framing, literal `\\xNN`, missing final newline, and broken pipe.
- Prove output length does not change resident high-water marks.
- Prove renderer failure cannot alter or roll back the committed Session state.
- Keep `libghostty` and VT emulation out of V1. Ghostty remains the terminal that displays OnePage's safe primary-screen records.

## Resulting issue plan

### Native Core prerequisite — keep separate, but narrow it

Add these implementation decisions:

- semantic domain methods and fixed snapshots, not raw export mirrors;
- generated host/Wasm ABI declaration plus a tiny version or fingerprint;
- disposable-instance or test-only behavioral conformance;
- explicit owned/borrowed lifetimes and stale-generation behavior;
- closed capacity, transition, compatibility, and runtime failures;
- no allocator fallback and no mock Core.

The deletion test is positive: deleting this module would redistribute JavaScriptCore lifetime, raw export lookup, numeric decoding, memory-window validation, and ABI compatibility logic back into Harness.

### Harness corrective issue — remain one issue

Add these implementation decisions:

- prepare complete transitions before durable commit;
- make post-commit publication infallible or reconstructably idempotent;
- classify failures as reusable owner, unavailable owner, or corrupted Session;
- keep physical Session mechanics internal while testing semantic recovery through Harness;
- make stale Core/Operation/Attempt/Projection references inert;
- make model interpretation pure and adapter admission owner-only;
- preserve digest-bound immutable Approval and explicitly reject mutable-source retry.

Do not create a separate semantic Session issue. Ghostty's snapshot decoder supports a deep codec behind the owner; it does not argue for another public lifecycle seam.

### Issue #13 — amend, do not replace

Add these implementation decisions:

- one fixed-window byte renderer for all hostile sources;
- trusted framing separated from untrusted body bytes;
- no VT parsing, `libghostty`, allocator fallback, alternate screen, or cursor addressing;
- adversarial split-point corpus and broken-pipe black-box tests;
- approval input only after a committed, regenerated `approval_required` Projection and returned through `Harness.offer`.

## Anti-lessons

- Do not copy Ghostty's broad getter-style public C surface; OnePage's Native Core is private and should be much deeper.
- Do not copy per-terminal threads, a forever-blocking mailbox, or best-effort dropped notifications.
- Do not expose a partially reconciled Session merely because a checkpoint is renderable.
- Do not copy mutable-source `allow_unsafe` retry for consequential Actions.
- Do not mistake a robust VT parser for safe terminal rendering.
- Do not use stack-first allocation with an invisible heap fallback inside the claimed memory budget.
- Do not import Ghostty's application or `libghostty-vt` in V1; use its contracts as design evidence.
