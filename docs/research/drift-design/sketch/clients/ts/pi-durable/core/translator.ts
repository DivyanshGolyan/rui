// The shared pi-durable translator (sketch, U12). Version-independent; every version layer
// (v1.6/, later others) is a thin shape adapter over these functions.
//
// Rules this file keeps:
// - It calls only `ruicode`'s public API. No wire types, no Host routes.
// - It adds no behavior. A pi-durable feature that needs logic Rui lacks is a Rui core gap
//   (filed and built in the Host first); until then the version layer does not export it.
// - Every mapping lives once, here: feed row -> entry, work -> live doc, tool -> app tool,
//   store failure -> session failure, rows -> reports.

import type { FeedEntry } from "../../src/feed.ts";
import type { AppTool } from "../../src/tools.ts";
import type { WatchEvent } from "../../src/watch.ts";

/** Version-neutral entry, the superset every layer's `EntryRecord` is shaped from. */
export interface NeutralEntry {
	/** Ordered within a conversation: position * 256 + ordinal (Rui's feed cursor). */
	id: number;
	kind: "user" | "assistant" | "tool_result" | "system" | "reset" | "compaction";
	/** Model-facing messages in pi-ai shapes (Message[]), built from the row and its content. */
	model?: readonly unknown[];
	data?: unknown;
	/** For reset and compaction: the first entry of the context it starts. */
	head?: number;
}

/** pi-ai message shapes are the layer's concern; the core passes neutral values. */
export interface Translator {
	/** Root conversation: `sessions.create` under the fixed key `pi-durable:<namespace>:root`. */
	root(namespace: string, spec: unknown): Promise<string>;

	/** A conversation id to its Session, importing it first when a legacy Storage is set. */
	open(conversationId: string): Promise<string | undefined>;

	/** One feed row to zero or more neutral entries (a call row joins its tool_result). */
	entries(row: FeedEntry): NeutralEntry[];

	/** The served work snapshot to the version-neutral run state (pi `pi.live`, `pi.inbox`). */
	live(work: Extract<WatchEvent, { type: "work" }>["work"]): NeutralLive;

	/**
	 * A pi tool registration to an app tool. `execute` becomes `run`; `replay` and the
	 * Harness's `restartLimit` become the declaration's policy; `api.output()` becomes
	 * `call.progress()`. `structuredOutput` and `details` have no Rui channel: a tool that
	 * declares `structuredOutputSchema` is refused here, with its name.
	 */
	tool(registration: NeutralToolRegistration): AppTool;

	/** Rows and line ends to pi reports: indeterminate or restart_limit results to
	 * `task_interrupted`, a failed compaction to `task_faulted`, store failure to
	 * `storage_failed`. Nothing else is reported: Rui keeps no report log. */
	reports(event: WatchEvent | { type: "ended"; error: Error }): NeutralReport[];

	/** RuiStoreFailedError and RuiUnavailableError after a fence, to the layer's failure. */
	failure(error: unknown): { kind: "session_failed"; cause: unknown } | undefined;
}

export interface NeutralLive {
	running: boolean;
	runFailure?: { reason: "model_error" | "aborted" | "interrupted" | "restart_limit" | "reset"; detail?: string };
	queued: number;
	tools: { action: string; name: string; progress?: string }[];
}

export interface NeutralToolRegistration {
	name: string;
	description: string;
	parameters: object;
	replay?: "safe" | "unsafe";
	structuredOutputSchema?: object;
	execute(args: unknown, api: { output(text: string): void; signal: AbortSignal }): Promise<{ output?: unknown[]; isError?: boolean }>;
}

export type NeutralReport =
	| { kind: "storage_failed"; error: unknown }
	| { kind: "task_interrupted"; conversationId: string; reason: "interrupted" | "restart_limit"; restarts: number; error: unknown }
	| { kind: "task_faulted"; conversationId: string; reason: "threw"; error: unknown };

export function createTranslator(_rui: unknown, _options: { namespace: string; legacy?: unknown; restartLimit: number; waitMs: number }): Translator {
	throw new Error("not implemented");
}
