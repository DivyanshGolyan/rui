// The client end of the Host's line (sketch, U3). One per `Rui` instance, opened at
// connect/attach and reopened after a drop. Private to the package: callers use
// `session.watch()` and `rui.tools.serve()`, never frames.
//
// Nudges are hints. On every (re)open the line reports `resync`, so readers re-read
// from their own cursors: reconnect and cold start are the same code.

import type { Socket } from "node:net";

/** A line token, as decimal text from `hello`. Claims and results carry it. */
export type LineToken = string & { readonly __line: unique symbol };

/** What a subscriber hears. Never a saved fact: read the feed or claim to get those. */
export type Nudge =
	| { readonly type: "changed"; readonly session: string }
	| { readonly type: "calls"; readonly lane: string }
	| { readonly type: "resync" }
	| { readonly type: "progress"; readonly session: string; readonly action: string; readonly attempt: number; readonly text: string }
	| { readonly type: "cancel"; readonly action: string; readonly attempt: number };

export interface LineListener {
	nudge(nudge: Nudge): void;
	/** The line ended for good: the Store failed or the Host is stopping. */
	end(error: Error): void;
}

/**
 * Owns the socket, framing (4-byte big-endian length + JSON), reconnect with backoff,
 * and the union of what every listener watches and serves, sent as `watch` and `serve`
 * frames whenever it changes.
 */
export class Line {
	#socket: Socket | undefined;
	#token: LineToken | undefined;
	readonly #watched = new Map<string, number>(); // session -> listener count
	readonly #lanes = new Map<string, number>();
	readonly #listeners = new Set<LineListener>();

	constructor(_open: () => Promise<Socket>, _fail: (error: Error) => void) {
		throw new Error("not implemented");
	}

	/** Resolves with the current token; waits while reconnecting. */
	token(): Promise<LineToken> {
		throw new Error("not implemented");
	}

	/** Adds `session` to the watched set for as long as the returned function is not called. */
	watch(_session: string, _listener: LineListener): () => void {
		throw new Error("not implemented");
	}

	/** Adds `lane` to the served set for as long as the returned function is not called. */
	serve(_lane: string, _listener: LineListener): () => void {
		throw new Error("not implemented");
	}

	/** Live progress for a call this process runs. Dropped silently while disconnected. */
	progress(_session: string, _action: string, _attempt: number, _text: string): void {
		throw new Error("not implemented");
	}

	close(): Promise<void> {
		throw new Error("not implemented");
	}
}
