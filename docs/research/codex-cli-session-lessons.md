# Lessons from Codex CLI for OnePage sessions

Research date: 2026-08-24
Codex revision: [`0d9bb6c34c2742ee8bcddfccb6404a447926ff9f`](https://github.com/openai/codex/tree/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f)

## Decision

OnePage should keep its session → append-only conversation tree → bounded model-context projection model. Codex contributes useful physical and replay semantics, but not an object model to copy:

1. freeze a fork at an exact committed history position;
2. make compaction an append-only replacement-context checkpoint;
3. reconstruct by scanning backward to a sufficient checkpoint, then replaying the surviving suffix forward;
4. keep canonical history ahead of rebuildable query/UI projections;
5. treat cwd and Git metadata as workspace identity hints, not repository reconstruction.

These semantics belong inside a OnePage session. A branch is a new leaf over a frozen conversation prefix, not a new resident agent and not automatically a new session.

## Canonical history is richer than model history

Codex's canonical JSONL union contains model response items alongside session metadata, compaction checkpoints, turn context, world-state records, security scores, and selected lifecycle events ([history types](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/history/src/lib.rs#L93-L105)). Its persistence policy excludes transient deltas, begin events, approval prompts, and warnings ([event policy](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/policy.rs#L86-L183)). Reconstruction feeds only response items and inter-agent communication into model history; turn context, world state, lifecycle, session, and security records hydrate other state or are ignored by the prompt reducer ([reconstruction reducer](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/session/rollout_reconstruction.rs#L320-L377)).

OnePage should make that separation structural rather than relying on one broad tagged union:

- immutable conversation entries: exactly the typed material eligible for future model context;
- an operation journal: intent, admission, delivery certainty, approval, execution, completion, and reconciliation facts;
- rebuildable projections: UI items, search/list metadata, accounting, and metrics.

An execution record must never become model-visible merely because a new event variant was added.

## Resume and fork

Codex distinguishes resume from fork. Resume reopens the existing rollout and preserves thread identity; fork creates a fresh thread and records source lineage ([initial-history variants](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/history/src/lib.rs#L209-L222), [fork creation](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/thread_manager.rs#L1172-L1199)). Fork preparation first persists and reserves the source, resolves a boundary, and only then loads inherited context; a requested boundary inside an in-progress turn is rejected ([preparation](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/thread-store/src/local/paginated_fork.rs#L15-L84), [boundary validation](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/thread-store/src/local/paginated_fork.rs#L111-L153)). Legacy snapshot code instead makes a mid-turn suffix explicit with an interrupted boundary ([interrupted snapshot](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/thread_manager.rs#L2168-L2241)).

The paginated format can reference rather than copy inherited history. A `HistoryPosition` identifies an immutable rollout plus exclusive ordinal and byte offset ([history position](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/protocol/src/protocol.rs#L2862-L2876)). Lineage resolution follows these pointers, rejects cycles, validates cutoffs, and returns ordered immutable segments ([lineage resolution](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/thread-store/src/local/rollout_lineage.rs#L55-L157)).

For OnePage:

- `resume(session, branch)` advances the same branch leaf;
- `fork(session, source_leaf, boundary)` creates a branch whose parent is that frozen boundary;
- the boundary names a committed conversation entry and operation-journal watermark;
- fork admission first publishes all source facts;
- initial fork support permits forks only at completed decision boundaries;
- readers validate session ownership, monotonic positions, bounds, and cycles.

OnePage already has stable entry IDs and parent links, so byte offsets should remain an internal storage-adapter detail. Do not copy Codex's one-thread-per-fork identity into the domain model.

## Compaction is a projection checkpoint

Codex compaction appends a checkpoint containing full `replacement_history`, window lineage, and resource-origin state rather than deleting old JSONL records ([compaction type](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/history/src/lib.rs#L141-L150)). Installation assigns stable item IDs and records the exact replacement history plus full world-state and turn-context baselines needed after the reset ([installation](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/session/mod.rs#L3396-L3440)).

The paginated loader scans newest-to-oldest until it has both a complete replacement-history checkpoint and compatible completed-turn context. Unsafe legacy compaction or rollback forces a conservative scan to the beginning ([cutoff rules](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/model_context.rs#L18-L47), [scan state](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/model_context.rs#L57-L176)). Reconstruction installs the newest surviving replacement history and replays its suffix forward ([reverse scan](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/session/rollout_reconstruction.rs#L113-L187), [forward replay](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/session/rollout_reconstruction.rs#L320-L377)).

This sharpens OnePage's ADR: compaction cannot mean only “summary text.” A `CompactionCheckpoint` should contain the source branch interval, exact ordered replacement projection, context-policy version, previous checkpoint ID, required environment/permission baseline, and a digest. Old conversation entries remain evidence; the checkpoint is authoritative only for model projection on descendants of its branch. Invalid checkpoints fall back to an older checkpoint or the root, never to a guessed context.

## Canonical log, derived indexes, and durability

Codex calls JSONL canonical and SQLite a rebuildable query projection. The JSONL write barrier completes before projection; SQLite may lag after failure but must not get ahead ([store boundary](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/thread-store/README.md#L7-L30), [write then project](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/thread-store/src/local/live_writer.rs#L309-L347)). OnePage should use the same direction of truth: conversation plus operation journal → model context → UI/search projections.

Codex's recorder is not a strict WAL example. It appends newline-delimited records and calls `flush`, but does not call `sync_all`/`fsync` at that barrier ([writer](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/recorder.rs#L1653-L1817), [line write](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/recorder.rs#L1935-L1973)). OnePage's intent-before-effect contract must be stronger: define the actual OS durability boundary and torn-tail recovery, and cross it before dispatching an external effect.

## Repository state is a separate claim

Codex records cwd and best-effort initial commit, branch, and repository URL ([session metadata](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/protocol/src/protocol.rs#L2878-L2940), [Git capture](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/recorder.rs#L1852-L1874)). Per-turn context persists effective cwd, workspace roots, permissions, and model settings ([turn context](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/protocol/src/protocol.rs#L3035-L3087)). This does not reconstruct dirty tracked files, the index, untracked files, ignored artifacts, submodules, or external command effects; resume uses the filesystem currently at that cwd.

OnePage must distinguish:

- conversation reconstruction: reproduce exact model context for a branch;
- workspace reconstruction: reproduce or verify the repository state on which an operation depended.

V1 should bind a session to `{repo identity, worktree identity, base commit/tree, cwd}` and record a workspace generation/fingerprint on each consequential operation. A resumed mutation compares the current generation with its expected generation and stops for reconciliation on mismatch. A later promise of full reconstruction requires content-addressed patches/blobs or Git object/ref checkpoints; transcript and shell output are insufficient.

## What not to copy

- Codex's active `ContextManager` retains an `Arc<Vec<ResponseItemEnvelope>>` and replaces it across compaction/rollback ([resident history](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/context_manager/history.rs#L45-L72)). OnePage should stream a bounded branch projection into its fixed page.
- `ResumedHistory` is an eager `Arc<Vec<RolloutItem>>`, and reconstruction itself calls this an eager bridge awaiting a lazy reverse source ([resume type](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/history/src/lib.rs#L209-L222), [eager bridge](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/session/rollout_reconstruction.rs#L119-L123)). OnePage's storage seam should be cursor-based from the start.
- Each Codex recorder owns a background task and 256-item channel ([recorder creation](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/rollout/src/recorder.rs#L815-L946)). OnePage needs a fixed host-owned writer/slot budget, not one live writer topology per sleeping agent.
- Do not copy Codex's broad product event taxonomy or filesystem-continuity assumption.

Codex's V1 subagent topology also exposes three specific anti-lessons. It has a product nesting-depth setting and maintains an in-memory agent tree plus per-session count ([depth setting](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/config/mod.rs#L858-L875), [registry](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/agent/registry.rs#L18-L36)). V1 resume walks open descendants breadth-first and reopens them ([resume walk](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/agent/control/spawn.rs#L891-L964)). Spawn constructs `InitialHistory::Forked` from copied parent rollout items ([copied fork](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/agent/control/spawn.rs#L850-L888)), while delegate startup holds a parent `Arc<Session>` and clones parent services into the child ([parent-coupled spawn](https://github.com/openai/codex/blob/0d9bb6c34c2742ee8bcddfccb6404a447926ff9f/codex-rs/core/src/codex_delegate.rs#L50-L123)). These are reasonable runtime conveniences for Codex, but conflict with OnePage's storage-first claim.

OnePage should have no product-level nesting-depth limit: capacity is controlled by bounded active slots while durable topology may be arbitrarily deep. Resuming one agent must not walk or awaken its descendants. A delegated child stores direct parent-agent and parent-operation identities plus a bounded delegation packet, never a copied parent transcript, and spawning must not require retaining the parent session object graph. A conversation fork separately stores its frozen parent entry within the same session.

## Concrete spec changes

1. Extend the conversation ADR's compaction definition from “summary entry” to a validated replacement-projection checkpoint that retains its source entries.
2. Specify `Session`, `BranchHead`, `ForkBoundary`, `CompactionCheckpoint`, and `WorkspaceBinding`. A branch head names a conversation entry plus a journal watermark.
3. Define resume as same-branch continuation and fork as a new branch over a frozen committed boundary; require a source publication barrier and reject in-progress boundaries in v1.
4. Define reconstruction as newest-valid-checkpoint selection plus forward replay, with digest, ownership, bounds, and cycle validation.
5. Keep conversation and operation facts in separate typed stores/reducers; keep UI/search metadata rebuildable.
6. Record workspace generation per consequential operation and explicitly state that v1 verifies continuity but does not recreate arbitrary repositories.
7. Specify the operation journal's real durability guarantee and torn-tail behavior.
8. Make history access cursor-based and bounded so the 64 KiB core never receives a resident full transcript.

These changes add durable identities and reducer rules, not resident machinery.
