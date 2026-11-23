// `session.watch()` (sketch, U4): the one way to follow a Session.
// Replaces `listActivity({ follow: true })`'s polling backoff and the local WriteWatch
// (notifications.ts), which only noticed this process's own writes.
//
// Saved facts come only from the feed reader (feed.ts `listActivity` pages, which own the
// cursor, `since`, D219 and content windows). The line only says when to read.

import type { FeedEntry } from "./feed.ts"; // existing module in the repo
import type { SessionStatus } from "./sessions.ts";

export interface WatchOptions {
	/** The `cursor` of the last entry the caller kept. Left out: from the beginning. */
	after?: string;
	/** Ends the iterator. */
	signal?: AbortSignal;
}

export type WatchEvent =
	/** A saved feed row, in order. `entry.cursor` is what to save for resuming. */
	| { readonly type: "entry"; readonly entry: FeedEntry }
	/** The served work snapshot changed (state, Turn, Operation, queued counts). */
	| { readonly type: "work"; readonly work: Pick<SessionStatus, "state" | "turn" | "operation" | "pendingMessages" | "attention" | "canStop" | "decide"> }
	/** Live tool progress. Never saved; a reconnect does not replay it. */
	| { readonly type: "progress"; readonly action: string; readonly attempt: number; readonly text: string };

/**
 * Loop, per Session:
 *   read pages from the cursor until caught up (the page mints `since`);
 *   wait for a `changed`/`resync` nudge (or abort);
 *   read again with `since`, which answers `not_modified` cheaply when nothing changed.
 * No timers. A dropped line arrives as `resync`. Store failure rejects `next()` with
 * RuiStoreFailedError.
 */
export function watch(_link: unknown, _session: string, _options?: WatchOptions): AsyncGenerator<WatchEvent, void, undefined> {
	throw new Error("not implemented");
}
