import { readPage } from "../src/feed.ts";
import { Follows, type LineControl } from "../src/follow.ts";
import type { Link } from "../src/sessions.ts";

type Exchange = Link["exchange"];

/**
 * A client whose line is scripted: `changed` and `resync` play the Host's frames, and `lines` records each watched set the
 * client sent. Reads go through `exchange`, so a test decides what the feed holds.
 */
export function scriptedLink(exchange: Exchange) {
	const lines: string[][] = [];
	// As the Host does: a watch set nudges each listed Session once, so the new watcher's first read comes from that nudge.
	const line: LineControl = { watch: (sessions) => {
		lines.push([...sessions]);
		for (const session of sessions) follows.nudge(session);
	} };
	const follows: Follows = new Follows((session, request) => readPage({ exchange }, session, request), line);
	const link: Link = { exchange, follows };
	return {
		link,
		follows,
		lines,
		changed: (session: string) => follows.nudge(session),
		resync: () => follows.nudgeAll(),
	};
}

/**
 * A Session's feed as the Host serves it: rows appended in order, pages of 16 from a cursor, and `not_modified` when the
 * request's token is the current one. `reads` counts every page request.
 */
export function fakeFeed(sessions: readonly string[] = ["k7m2qx"]) {
	const rows = new Map<string, { position: number; key: string }[]>(sessions.map((session) => [session, []]));
	let reads = 0;
	const exchange: Exchange = async (path, build) => {
		if (path !== "/v1/activity-page") throw new Error(`unexpected ${path}`);
		reads++;
		const request = JSON.parse(build("store")) as { session: string; position: string; ordinal: string | null; since: string | null };
		const feed = rows.get(request.session);
		if (!feed) throw new Error(`unknown session ${request.session}`);
		const token = `t${feed.length}`;
		if (request.since === token) return json({ version: "24", type: "activity_page", delta: "not_modified", since: token });
		const from = Number(request.position);
		const after = feed.filter((row) => row.position > from);
		const items = after.slice(0, 16);
		const last = feed.at(-1)?.position ?? 0;
		return json({
			version: "24", type: "activity_page", delta: "full", since: token,
			items: items.map((row) => ({ position: String(row.position), ordinal: "0", at: "1", value: { stop: { key: row.key, turn: null, cutoff: "1", completion: "completed" } } })),
			more: after.length > items.length, end: String(last),
			aggregates: { as_of: String(after.length > items.length ? items.at(-1)?.position ?? last : last), call_activity: { total: "0", entries: [] }, queued: { count: "0" } },
			work: { actions: { stop: false, interrupt: null, decide: null }, state: { kind: "working", since: "1" } },
		});
	};
	return {
		exchange,
		/** Commits rows to `session`, in order; the test then plays the nudge. */
		append(session: string, ...keys: string[]): void {
			const feed = rows.get(session);
			if (!feed) throw new Error(`unknown session ${session}`);
			for (const key of keys) feed.push({ position: feed.length + 1, key });
		},
		reads: () => reads,
	};
}

function json(value: unknown): Buffer {
	return Buffer.from(JSON.stringify(value));
}

/** The next `count` entries' keys, pulled one at a time. A `stop` row carries its key. */
export async function nextKeys(feed: AsyncIterator<unknown>, count: number): Promise<string[]> {
	const keys: string[] = [];
	for (let index = 0; index < count; index++) {
		const next = await feed.next();
		if (next.done) throw new Error("the feed ended");
		keys.push(keyOf(next.value));
	}
	return keys;
}

function keyOf(entry: unknown): string {
	const value = entry as { kind: string; key?: string };
	if (value.kind !== "stop" || value.key === undefined) throw new Error(`unexpected entry ${JSON.stringify(entry)}`);
	return value.key;
}

/** Lets pending promise continuations run, without a timer. */
export async function settle(turns = 20): Promise<void> {
	const { setImmediate: turn } = await import("node:timers/promises");
	for (let index = 0; index < turns; index++) await turn();
}
