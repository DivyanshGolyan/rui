// ruicode/pi-durable/v1.6 (sketch, U12): pi-durable 1.6.0's names and shapes over the
// shared translator. `ruicode/pi-durable` re-exports the newest layer.
//
// A name pi-durable 1.6.0 exports that Rui does not support is simply absent here, so a
// caller's compiler names it. Supported names keep 1.6.0's signatures, narrowed where Rui
// supports only part (for example `hook` accepts only observing handlers).
//
// Exported: Harness, ROOT_CONVERSATION_ID, createRegistry, defineExtension, defineTool,
//   section, hook (observing only), ConversationTranscript, AssistantEntry, UserEntry,
//   ToolResultEntry, SystemEntry, ResetEntry, CompactionEntry, SessionFailed,
//   DEFAULT_RESTART_LIMIT, MemoryStorage (a temporary Rui Store, for pi-durable's tests),
//   and ruiStorage (Rui's stand-in for a pi `Storage`).
// Not exported (Rui gaps or Drift drops): defineDoc, defineDocFamily, defineEntry,
//   defineTask, defineSignal, hookTask, wrapSection, createSession, fork, the task graph,
//   GenerationTask.beforeRequest/beforeProviderRequest/onYield/afterTools/afterRun,
//   ToolTask.beforeTool, ConversationBusy/ConversationIdle (until whenBusy is decided).

import type { Translator } from "../core/translator.ts";

type Context = { readonly signal?: AbortSignal };

export const ROOT_CONVERSATION_ID = "root" as const;
export const DEFAULT_RESTART_LIMIT = 5;

/** 1.6.0's `SessionFailed`: the Store failed; reopen after repair. */
export class SessionFailed extends Error {
	constructor(cause: unknown) {
		super("Session failed", { cause });
	}
}

/** Stands where pi-durable takes a `Storage`. `legacy` is read through pi-durable's own
 * Storage interface by the importer, lazily on first open of each conversation. */
export interface RuiStorage {
	readonly __ruiStorage: unique symbol;
}
export function ruiStorage(_options: ({ attach: string } | { settings: unknown }) & { legacy?: unknown; namespace?: string }): RuiStorage {
	throw new Error("not implemented");
}

export interface HarnessOptions {
	readonly registry: unknown;
	readonly settings?: { readonly restartLimit?: number };
	readonly onReport?: (report: unknown) => void;
	// `models` is absent: Rui's Host owns providers (mapping table, pi-ai rows).
}

export interface Conversation {
	readonly id: string;
	submit(submission: { type: "input"; content: string; requestId?: string }, context: Context): Promise<Submission>;
	reset(handoff: string | undefined, context: Context): Promise<void>;
	configure(change: { model?: unknown; thinkingLevel?: unknown; instructions?: string }, context: Context): Promise<void>;
	abort(context: Context): Promise<void>;
	waitForIdle(context: Context): Promise<void>;
	entries(query: { minEntryId?: number; maxEntryId?: number; order?: "ascending" | "descending" }, limit: number, cursor: unknown, context: Context): Promise<{ items: unknown[]; next?: unknown }>;
	watch(context: Context, window?: { from?: number; min?: number; max?: number }): Promise<unknown>;
}

export interface Submission {
	readonly id: string;
	/** Resolves at the Turn's ending row for this input: done with the answer, or unanswered. */
	wait(context: Context): Promise<{ status: "done" | "unanswered"; reason?: string }>;
}

export interface Harness {
	root(context: Context, options?: { agent?: unknown }): Promise<Conversation>;
	conversation(id: string, context: Context): Promise<Conversation | undefined>;
	createConversation(options: unknown, context: Context): Promise<Conversation>;
	/** No-op: the Host resumes eligible work when it starts. */
	resume(): void;
	close(context: Context): Promise<void>;
}

export const Harness = {
	open(_storage: RuiStorage, _options: HarnessOptions, _context: Context): Promise<Harness> {
		throw new Error("not implemented");
	},
};

/** 1.6.0 shape; `execute` runs in this process as an app tool (core/translator.ts tool()). */
export function defineTool<T>(tool: T): T {
	return tool;
}

/** Observing handlers only. Each is driven by the watch: afterResponse from model_call
 * rows, afterTool from tool_result rows, the compaction handler from compacted rows. */
export interface ObservingHooks {
	afterResponse?(response: unknown): void | Promise<void>;
	afterTool?(result: unknown): void | Promise<void>;
	afterCompaction?(summary: unknown): void | Promise<void>;
}
export declare const GenerationTask: { readonly __task: "pi.generation" };
export declare const ToolTask: { readonly __task: "pi.tool" };
export declare const CompactionTask: { readonly __task: "pi.compaction" };
/** 1.6.0's `hook(task, handlers)`, typed so a loop-changing handler does not compile. */
export function hook(_task: typeof GenerationTask | typeof ToolTask | typeof CompactionTask, _handlers: ObservingHooks): unknown {
	throw new Error("not implemented");
}

/** Every layer shares one translator per open Harness. */
export type _Layer = (translator: Translator) => Harness;
