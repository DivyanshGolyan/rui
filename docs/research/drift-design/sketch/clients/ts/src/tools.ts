// Client tools (sketch, U6/U7). One value, `appTool(...)`, is both the declaration the
// Host stores and the handler this process runs, so the two cannot drift apart.
//
//   declare: rui.sessions.create({ appTools }) / session.update({ appTools })  (durable)
//   serve:   rui.tools.serve(lane, tools)                                      (this process)
//
// Serving claims calls through `/v1/app-call-claim` with the digests of the tools it
// holds, so after a deploy an old process never runs a call made against a newer
// declaration of the same name.

import type { Session } from "./sessions.ts";

export type JsonSchema = Record<string, unknown>;

export interface AppToolCall {
	/** The Action id, as in the feed. */
	readonly action: string;
	/** 1 for the first run; higher only for a `replay: "safe"` tool rerun after a crash. */
	readonly attempt: number;
	/** The Session whose model made the call (the lane root or one of its helpers). */
	readonly session: string;
	/** Aborted when the call is stopped, or when its deadline passes. */
	readonly signal: AbortSignal;
	/** Live progress. Never saved; the model never sees it. */
	progress(text: string): void;
}

export type AppToolResult =
	| { readonly content: string | readonly AppToolPart[] }
	| { readonly error: string };

export type AppToolPart =
	| { readonly type: "text"; readonly text: string }
	| { readonly type: "image"; readonly mediaType: "image/png" | "image/jpeg"; readonly bytes: Uint8Array };

export interface AppToolOptions<Args> {
	name: string;
	description: string;
	inputSchema: JsonSchema;
	/** `safe`: Rui sends the call again after a crash, at most `restartLimit` times. Default `unsafe`. */
	replay?: "safe" | "unsafe";
	/** Default 5 (pi-durable DEFAULT_RESTART_LIMIT). */
	restartLimit?: number;
	/** How long a call may wait for this process (or another) to claim and answer it. */
	waitMs: number;
	/** Throwing gives the model an error result with the message, like `{ error }`. */
	run(args: Args, call: AppToolCall): Promise<AppToolResult>;
}

/** A declared, runnable tool. Opaque: its record digest is computed once, here. */
export interface AppTool {
	readonly name: string;
	readonly __appTool: unique symbol;
}

export function appTool<Args = unknown>(_options: AppToolOptions<Args>): AppTool {
	throw new Error("not implemented");
}

export interface Serving {
	/** Stops claiming; waits for calls this process runs to answer. */
	stop(): Promise<void>;
	/** Calls this process is running now. */
	readonly running: number;
}

export interface ServeOptions {
	/** Most calls this process runs at once. Default 16. Past it, it stops claiming. */
	concurrency?: number;
}

/**
 * `rui.tools.serve(lane, tools)`: on each `calls` nudge for `lane`, while under
 * `concurrency`, claim until the Host answers `null`. Run the handler; answer with
 * `/v1/app-call-result` under a key derived from (action, attempt), retried until
 * the Host answers `accepted` or `ignored`. A `cancel` nudge aborts the call's signal.
 * A dropped line ends this process's claims on the Host side; the handlers still running
 * finish, and their answers come back `ignored`.
 */
export class Tools {
	serve(_lane: Session | string, _tools: readonly AppTool[], _options?: ServeOptions): Serving {
		throw new Error("not implemented");
	}
}
