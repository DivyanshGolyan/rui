import type { FeedKind, PageRequest } from "./feed.ts";
import type { components } from "./wire.ts";

type Reply = components["schemas"]["ActivityPageReply"];
/** A page of rows; a `not_modified` reply carries none. */
export type Page = Extract<Reply, { delta: "full" }>;

/** The most Sessions one line may watch (docs/contracts/inspection.md#live-line). */
export const MAX_WATCHED_SESSIONS = 256;

/** A Session id in the Host's grammar: six characters of its Crockford alphabet. The Host closes a line whose watch set breaks it. */
const SESSION_ID = /^[0-9a-hjkmnp-tv-z]{6}$/;

/** Replaces the held line's watched set. An empty set closes the line. */
export interface LineControl {
	watch(sessions: readonly string[]): void;
}

/** Reads one page of a Session's feed from a cursor. */
export type PageReader = (session: string, request: PageRequest) => Promise<Reply>;

export interface Cursor {
	position: string;
	ordinal: string | null;
	since: string | null;
}

/**
 * The one way this client follows a Session. Every watcher of the client shares one line. A nudge (`changed`, `resync`,
 * a reconnect) makes each affected watcher read its own cursor once. The nudge carries no fact: rows come from feed reads.
 */
export class Follows {
	readonly #read: PageReader;
	readonly #line: LineControl;
	readonly #sessions = new Map<string, SessionFollow>();

	constructor(read: PageReader, line: LineControl) {
		this.#read = read;
		this.#line = line;
	}

	/**
	 * Registers a watcher at `cursor`. A Session's first watcher adds it to the line, and the Host answers a watch set with one
	 * nudge per listed Session, which reads it. A later watcher of a watched Session gets no frame, so it reads itself.
	 */
	join(session: string, cursor: Cursor, kinds: readonly FeedKind[]): Watcher {
		if (!SESSION_ID.test(session)) throw new RangeError(`not a Session id: ${JSON.stringify(session)}`);
		let follow = this.#sessions.get(session);
		const added = follow === undefined;
		if (!follow) {
			if (this.#sessions.size >= MAX_WATCHED_SESSIONS) throw new RangeError(`a client watches at most ${MAX_WATCHED_SESSIONS} Sessions`);
			follow = new SessionFollow(session, this);
			this.#sessions.set(session, follow);
		}
		const watcher = new Watcher(cursor, kinds, follow);
		follow.watchers.add(watcher);
		if (added) this.#line.watch([...this.#sessions.keys()]);
		else follow.drive();
		return watcher;
	}

	/** Releases a watcher. The last watcher of a Session drops it from the line; the last one of the client closes the line. */
	leave(watcher: Watcher): void {
		const follow = watcher.follow;
		if (!follow.watchers.delete(watcher)) return;
		watcher.release();
		if (follow.watchers.size === 0 && this.#sessions.get(follow.session) === follow) {
			this.#sessions.delete(follow.session);
			this.#line.watch([...this.#sessions.keys()]);
		}
	}

	/** A commit touched `session`, or the Host asked for a re-read: each of its watchers reads once. */
	nudge(session: string): void {
		this.#sessions.get(session)?.nudge();
	}

	/** The change ring no longer covers the line: every watched Session is re-read from its cursors. */
	nudgeAll(): void {
		for (const follow of this.#sessions.values()) follow.nudge();
	}

	/** A read of `follow` failed: its watchers end with `error`. A Session that is no longer registered only ends its own watchers. */
	failFollow(follow: SessionFollow, error: Error): void {
		if (this.#sessions.get(follow.session) === follow) {
			this.#sessions.delete(follow.session);
			this.#line.watch([...this.#sessions.keys()]);
		}
		follow.failWatchers(error);
	}

	/** The client can no longer follow: every watcher ends with `error`, and the line closes. */
	fail(error: Error): void {
		const all = [...this.#sessions.values()];
		this.#sessions.clear();
		for (const follow of all) follow.failWatchers(error);
		this.#line.watch([]);
	}

	/** The client's page reader, for the read loop of each watched Session. */
	get read(): PageReader {
		return this.#read;
	}
}

/** The watchers of one Session. At most one feed read is in flight for it; watchers at the same cursor share that read. */
class SessionFollow {
	readonly session: string;
	readonly watchers = new Set<Watcher>();
	readonly #follows: Follows;
	#reading = false;
	/** Counts nudges. A read issued before the latest nudge may miss its commit, so its reply leaves the watchers due. */
	#nudges = 0;

	constructor(session: string, follows: Follows) {
		this.session = session;
		this.#follows = follows;
	}

	nudge(): void {
		this.#nudges++;
		for (const watcher of this.watchers) watcher.due = true;
		this.drive();
	}

	/** Starts the read loop unless one is running; a running loop re-checks for due watchers after each read. */
	drive(): void {
		if (this.#reading) return;
		this.#reading = true;
		void this.#run();
	}

	async #run(): Promise<void> {
		try {
			for (let next = this.#nextDue(); next !== undefined; next = this.#nextDue()) {
				const key = next.key;
				const stamp = this.#nudges;
				const page = await this.#follows.read(this.session, next.request);
				const settled = stamp === this.#nudges;
				for (const watcher of this.watchers) {
					if (watcher.due && watcher.isWaitingAt(key)) watcher.deliver(page, settled);
				}
			}
		} catch (error) {
			this.#reading = false;
			this.#follows.failFollow(this, error instanceof Error ? error : new Error(String(error)));
			return;
		}
		// No await since the last check: a nudge either marked a watcher due before that check, or finds the loop cleared.
		this.#reading = false;
	}

	#nextDue(): Watcher | undefined {
		for (const watcher of this.watchers) if (watcher.due && !watcher.hasPages) return watcher;
		return undefined;
	}

	failWatchers(error: Error): void {
		const watchers = [...this.watchers];
		this.watchers.clear();
		for (const watcher of watchers) watcher.fail(error);
	}
}

/** One consumer's cursor and the pages it has not yet taken. The Session's read loop delivers pages; `take` waits for one. */
export class Watcher {
	position: string;
	ordinal: string | null;
	since: string | null;
	readonly kinds: readonly FeedKind[];
	readonly follow: SessionFollow;
	/** A read is owed from this cursor: set by a nudge, by a `more` page, and by joining. */
	due = true;
	readonly #pages: Page[] = [];
	#error: Error | undefined;
	#wake: (() => void) | undefined;

	constructor(cursor: Cursor, kinds: readonly FeedKind[], follow: SessionFollow) {
		this.position = cursor.position;
		this.ordinal = cursor.ordinal;
		this.since = cursor.since;
		this.kinds = kinds;
		this.follow = follow;
	}

	get hasPages(): boolean {
		return this.#pages.length > 0;
	}

	get request(): PageRequest {
		return { end: null, position: this.position, ordinal: this.ordinal, since: this.since, kinds: this.kinds };
	}

	/** Watchers with equal keys read the same request. */
	get key(): string {
		return JSON.stringify([this.position, this.ordinal, this.since, this.kinds]);
	}

	isWaitingAt(key: string): boolean {
		return this.key === key && !this.hasPages;
	}

	/**
	 * Applies a page read from this cursor. A `not_modified` reply moves only the token. `settled` is false when a nudge
	 * arrived after the read was issued: the rows are still this cursor's facts, but the watcher stays due for another read.
	 */
	deliver(page: Reply, settled: boolean): void {
		if (page.delta === "not_modified") {
			this.since = page.since;
			this.due = !settled;
			return;
		}
		this.#pages.push(page);
		const last = page.items.at(-1);
		if (page.more && last) {
			this.position = last.position;
			this.ordinal = last.ordinal;
			this.since = null;
			this.due = true;
		} else {
			this.position = page.end;
			this.ordinal = null;
			this.since = page.since;
			this.due = !settled;
		}
		this.#notify();
	}

	fail(error: Error): void {
		this.#error = error;
		this.#notify();
	}

	/** Waits for the next page, resolving `undefined` once `signal` aborts. Taking a page starts the next owed read. */
	async take(signal: AbortSignal | undefined): Promise<Page | undefined> {
		for (;;) {
			if (this.#error) throw this.#error;
			const page = this.#pages.shift();
			if (page !== undefined) {
				if (this.due) this.follow.drive();
				return page;
			}
			if (signal?.aborted) return undefined;
			await new Promise<void>((resolve) => {
				const wake = () => {
					signal?.removeEventListener("abort", wake);
					this.#wake = undefined;
					resolve();
				};
				this.#wake = wake;
				signal?.addEventListener("abort", wake, { once: true });
			});
		}
	}

	/** A released watcher neither takes nor receives pages again. */
	release(): void {
		this.#pages.length = 0;
		this.due = false;
		this.#notify();
	}

	#notify(): void {
		const wake = this.#wake;
		this.#wake = undefined;
		wake?.();
	}
}
