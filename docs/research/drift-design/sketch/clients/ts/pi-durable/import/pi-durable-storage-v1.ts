// Reader spoke: pi-durable `Storage` -> Transcript v1 (sketch, U11).
//
// It reads only through pi-durable's own `Storage` methods, so it works with Drift's MySQL
// storage or any other: `scanConversations`, `scanEntries` (ascending), and
// `findLatestHeadMarker` for a check. It never touches tables.
//
// One spoke per foreign format version. Drift's storage implements pi-durable 1.4.0's
// Storage; whether 1.4 and 1.6 need two spokes is open question 7 in design.md.

import type { Transcript, TranscriptItem } from "../../src/transcript.ts";

/** The subset of pi-durable's `Storage` this reader needs, structurally typed so any
 * version whose methods match can be passed. */
export interface PiStorageReader {
	conversation(id: unknown, context: unknown): Promise<unknown | undefined>;
	scanConversations(query: { order?: "ascending" | "descending" }, limit: number, cursor: unknown, context: unknown): Promise<{ items: readonly { id: unknown }[]; next?: unknown }>;
	scanEntries(query: { conversationId: unknown; order?: "ascending" | "descending" }, limit: number, cursor: unknown, context: unknown): Promise<{ items: readonly PiEntry[]; next?: unknown }>;
}

export interface PiEntry {
	readonly id: unknown;
	readonly kind: string;
	readonly model?: readonly unknown[];
	readonly data?: unknown;
	readonly head?: unknown;
}

/**
 * Entry kinds mapped, one to one:
 *   pi.user        -> user
 *   pi.assistant   -> assistant (pi-ai AssistantMessage: text, thinking with signature as a
 *                     reasoning bag of family "openai-responses", toolCall)
 *   pi.tool-result -> tool_result (the diagnostics block stays in the text the model saw)
 *   pi.system      -> instructions
 *   pi.reset       -> head { headOrdinal: own ordinal, text: handoff }
 *   pi.compaction  -> head { headOrdinal: ordinal of `head`, text: summary }
 * Entries whose `model` is absent (display-only, custom kinds) are counted and skipped:
 * they changed nothing the model saw. A fork's inherited history (`parent`) is read
 * through the parent up to `at`, so the import is the conversation's linear view.
 */
export function readConversation(_storage: PiStorageReader, _conversationId: unknown, _options: { namespace: string; context: unknown }): Transcript {
	throw new Error("not implemented");
}

/** Pure: one pi entry to zero or one item, given the ordinal map built while scanning
 * (pi EntryId -> item ordinal; app-side memory, not Host memory). */
export function mapEntry(_entry: PiEntry, _ordinals: ReadonlyMap<unknown, number>, _ordinal: number): TranscriptItem | { skipped: string } {
	throw new Error("not implemented");
}

/** Eager import: every conversation, in ascending id order, each through importTranscript.
 * Idempotent: a sealed source returns `alreadyImported`. */
export function importAll(_rui: unknown, _storage: PiStorageReader, _options: { namespace: string; spec: unknown; context: unknown }): Promise<{ imported: number; already: number; failed: { id: unknown; error: unknown }[] }> {
	throw new Error("not implemented");
}

/** Lazy import of one conversation (used by ruiStorage({ legacy }) on first open). */
export function importConversation(_rui: unknown, _storage: PiStorageReader, _conversationId: unknown, _options: { namespace: string; spec: unknown; context: unknown }): Promise<{ session: string }> {
	throw new Error("not implemented");
}
