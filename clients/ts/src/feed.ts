// The Session feed: `listActivity` is an async iterator over /v1/activity-page
// (D9, D10, D117, A-D117, D134, D168). The Host sends rows with content
// references only, and no cursor type. The client encodes the cursor from a
// row's position and ordinal, and fills `text` from /v1/activity-content, so
// the Host holds no reply buffer for either (D168).

import type { Link } from "./sessions.ts";
import { WIRE_VERSION } from "./transport.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];
type Row = Schemas["ActivityItem"];

/** The row kinds the Host sends today. */
type WireKind = Schemas["ActivityPageRequest"]["kinds"][number];
/** Every kind the Host's feed has, in its own order. */
export const FEED_KINDS = [
	"admission",
	"user",
	"assistant",
	"call",
	"tool_result",
	"hosted_call",
	"turn_ended",
	"stop",
	"sent",
	"send_failed",
	"received",
	"approval_requested",
	"session_changed",
	"compacted",
] as const satisfies readonly WireKind[];
export type FeedKind = (typeof FEED_KINDS)[number];
// A kind the wire gains fails to compile here until the list has it.
const complete: [Exclude<WireKind, FeedKind>] extends [never] ? true : never = true;
void complete;

/** Entry text is inline up to this many bytes (D168). */
export const INLINE_TEXT_BYTES = 16 * 1024;
const PAGE_ROWS = 16;
const FIRST_POLL_MS = 250;
const MAX_POLL_MS = 2_000;
/** The only endings whose `turn_ended` entry carries text (D168). */
const ENDINGS_WITH_TEXT = new Set(["provider_refused", "failed"]);

export interface ListActivityOptions {
	/** The `cursor` of the last entry read. Left out, the feed starts at its beginning. */
	after?: string;
	/**
	 * Follows new entries, polling at 250 ms rising to 2 s only while busy.
	 * An empty idle/finished/failed/stopped page with nothing queued sleeps without a timer
	 * until send/update/decide/interrupt/stop succeeds through any handle for this Session
	 * on this Rui instance. Writes from another process to the same Store are not noticed
	 * while asleep. `signal` abort ends the iterator even while asleep.
	 */
	follow?: boolean;
	/** Only these kinds, by their wire names. Left out, every kind. */
	kinds?: readonly FeedKind[];
	/** Ends the iterator, even while it waits for new entries: a pending `next()` then resolves as done. */
	signal?: AbortSignal;
}

/** Maps only the row's own keys; nested values retain their wire spelling (D128). */
type CamelKey<Key extends string> = Key extends `${infer Head}_${infer Tail}` ? `${Head}${Capitalize<CamelKey<Tail>>}` : Key;
type CamelRow<Payload> = { [Key in keyof Payload as Key extends "session" ? "sessionId" : Key extends string ? CamelKey<Key> : Key]: Payload[Key] };

type EntryText = {
	/** The row's text, when this kind carries it and it fits inline. */
	text?: string;
	/** Text exceeds 16 KiB: use `session.readContent(entry)`. */
	truncated?: boolean;
	/** The text's length in bytes, when this kind carries text. */
	contentBytes?: string;
};

type EntryFromRow<R extends Row> = R extends Row ? {
	[Kind in keyof R["value"]]: Omit<R, "value"> & { kind: Kind; cursor: string }
		& CamelRow<R["value"][Kind]>
		& ("content" extends keyof R["value"][Kind] ? EntryText : {});
}[keyof R["value"]] : never;

/** A discriminated wire-row union with top-level camelCase fields and an opaque continuation `cursor`. */
export type FeedEntry = EntryFromRow<Row>;

/** An opaque cursor: after the row at this position and ordinal. */
export function encodeCursor(position: string, ordinal: string): string {
	return Buffer.from(`1:${position}:${ordinal}`).toString("base64url");
}

export function decodeCursor(cursor: string): { position: string; ordinal: string } {
	const match = /^1:(0|[1-9][0-9]*):(0|[1-9][0-9]*)$/.exec(Buffer.from(cursor, "base64url").toString("utf8"));
	if (!match) throw new RangeError("not a feed cursor");
	return { position: match[1] as string, ordinal: match[2] as string };
}

function camel(name: string): string {
	if (name === "session") return "sessionId";
	return name.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());
}

function camelCase(row: Record<string, unknown>): Record<string, unknown> {
	return Object.fromEntries(Object.entries(row).map(([name, value]) => [camel(name), value]));
}

function isReference(value: unknown): value is Schemas["ActivityItemContent"] {
	return typeof value === "object" && value !== null && "bytes" in value && "sha256" in value;
}

/** Builds an entry from a row, without its text. Returns the content reference when text is to be read. */
function entryOf(row: Row): { entry: FeedEntry; reference: Schemas["ActivityItemContent"] | undefined } {
	const [kind, payload] = Object.entries(row.value)[0] as [FeedKind, Record<string, unknown>];
	const reference = isReference(payload.content) ? payload.content : undefined;
	const wanted = kind !== "turn_ended" || ENDINGS_WITH_TEXT.has(String(payload.ending));
	const entry = {
		kind,
		cursor: encodeCursor(row.position, row.ordinal),
		position: row.position,
		ordinal: row.ordinal,
		at: row.at,
		...camelCase(payload),
		...(reference && wanted ? { contentBytes: reference.bytes } : {}),
	} as FeedEntry; // Object.entries erases the generated kind/payload correlation at this boundary.
	return { entry, reference: reference && wanted ? reference : undefined };
}

function activityBody(store: string, session: string, request: { end: string | null; position: string; ordinal: string | null; kinds: readonly FeedKind[] }): string {
	return JSON.stringify({
		version: WIRE_VERSION,
		kind: "activity_page",
		store,
		session,
		end: request.end,
		position: request.position,
		ordinal: request.ordinal,
		direction: "forward",
		kinds: [...request.kinds],
		limit: String(PAGE_ROWS),
	} satisfies Schemas["ActivityPageRequest"]);
}

function contentBody(store: string, session: string, entry: { position: string; ordinal: string }): string {
	return JSON.stringify({
		version: WIRE_VERSION,
		kind: "activity_content",
		store,
		session,
		position: entry.position,
		ordinal: entry.ordinal,
	} satisfies Schemas["ActivityContentRequest"]);
}

/** The Host stores up to a little under 1 GiB of text in one entry. */
const MAX_CONTENT_BYTES = 1024 * 1024 * 1024;

/** The whole text of an entry that has some, as UTF-8 bytes, however long (D134). */
export function readContentBytes(link: Link, session: string, entry: { position: string; ordinal: string }): Promise<Buffer> {
	return link.exchange("/v1/activity-content", (store) => contentBody(store, session, entry), undefined, { max: MAX_CONTENT_BYTES });
}

/** The whole text of an entry as a string. A text past the JavaScript string limit (about 512 MiB) throws; use `readContentBytes`. */
export async function readContent(link: Link, session: string, entry: { position: string; ordinal: string }): Promise<string> {
	return (await readContentBytes(link, session, entry)).toString("utf8");
}

/** Waits `ms`, or less when `signal` aborts. */
function pause(ms: number, signal: AbortSignal | undefined): Promise<void> {
	return new Promise((resolve) => {
		if (signal?.aborted) return resolve();
		const done = () => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", done);
			resolve();
		};
		const timer = setTimeout(done, ms);
		signal?.addEventListener("abort", done, { once: true });
	});
}

export async function* listActivity(link: Link, session: string, options: ListActivityOptions = {}): AsyncGenerator<FeedEntry, void, undefined> {
	// The Host wants kinds in its own order, each once.
	const kinds = options.kinds === undefined ? FEED_KINDS : FEED_KINDS.filter((kind) => options.kinds?.includes(kind));
	let position = "0";
	let ordinal: string | null = null;
	if (options.after !== undefined) {
		const cursor = decodeCursor(options.after);
		position = cursor.position;
		ordinal = cursor.ordinal;
	}
	let pinnedEnd: string | null = null;
	let wait = FIRST_POLL_MS;
	const { signal } = options;
	const watcher = options.follow ? link.activity?.watch(session) : undefined;
	try {
		while (!signal?.aborted) {
			// Capture before I/O so a write racing an idle reply cannot be lost.
			const revision = watcher?.revision ?? 0;
			const page = JSON.parse(
				(await link.exchange("/v1/activity-page", (store) => activityBody(store, session, { end: pinnedEnd, position, ordinal, kinds }))).toString("utf8"),
			) as Schemas["ActivityPageReply"];
			for (const row of page.items) {
				// Cancellation is honoured before each entry, and again after any read that took time.
				if (signal?.aborted) return;
				const { entry, reference } = entryOf(row);
				if (reference && "content" in entry) {
					if (Number(reference.bytes) > INLINE_TEXT_BYTES) {
						entry.truncated = true;
					} else {
						const prefix = await link.exchange("/v1/activity-content", (store) => contentBody(store, session, row), undefined, { prefix: INLINE_TEXT_BYTES });
						entry.text = prefix.toString("utf8");
					}
				}
				if (signal?.aborted) return;
				yield entry;
				position = row.position;
				ordinal = row.ordinal;
			}
			if (page.more) {
				// A bounded read keeps the end the first page named; a following one asks again.
				pinnedEnd = options.follow ? null : page.end;
				wait = FIRST_POLL_MS;
				continue;
			}
			if (!options.follow) return;
			pinnedEnd = null;
			// Exhausted: everything the filter matches up to the end has been read, so the next poll starts at the end
			// rather than rescanning the rows between the last match and it.
			position = page.end;
			ordinal = null;
			if (page.items.length > 0) wait = FIRST_POLL_MS;
			else if (page.queued.count === "0" && dormant(page.work.state.kind)) {
				await (watcher ? watcher.wait(revision, signal) : untilAbort(signal));
				wait = FIRST_POLL_MS;
			} else {
				await pause(wait, signal);
				wait = Math.min(wait * 2, MAX_POLL_MS);
			}
		}
	} finally {
		watcher?.close();
	}
}

function dormant(kind: Schemas["WorkStateJson"]["kind"]): boolean {
	return kind === "idle" || kind === "finished" || kind === "failed" || kind === "stopped";
}

/** A bare internal Link has no local writes to observe; cancellation still ends its idle wait. */
function untilAbort(signal: AbortSignal | undefined): Promise<void> {
	return new Promise((resolve) => {
		if (signal?.aborted) resolve();
		else signal?.addEventListener("abort", () => resolve(), { once: true });
	});
}

export interface SearchActivityOptions {
	/** Resume before this search entry's cursor. */
	before?: string;
	kinds?: readonly FeedKind[];
	limit?: number;
	signal?: AbortSignal;
}

export type ActivitySearchEntry = Schemas["ActivitySearchReply"]["items"][number] & { cursor: string };

/** Search public feed text newest first. Empty budget-limited pages still advance. */
export async function* searchActivity(link: Link, session: string, query: string, options: SearchActivityOptions = {}): AsyncGenerator<ActivitySearchEntry, void, undefined> {
	const bytes = Buffer.byteLength(query, "utf8");
	if (bytes === 0 || bytes > 256 || Buffer.from(query, "utf8").toString("utf8") !== query) throw new RangeError("query must be 1–256 UTF-8 bytes");
	const limit = options.limit ?? PAGE_ROWS;
	if (!Number.isInteger(limit) || limit < 1 || limit > PAGE_ROWS) throw new RangeError("limit must be 1–16");
	const kinds = options.kinds === undefined ? FEED_KINDS : FEED_KINDS.filter((kind) => options.kinds?.includes(kind));
	let before = options.before === undefined ? null : decodeCursor(options.before);
	while (!options.signal?.aborted) {
		const page = JSON.parse((await link.exchange("/v1/activity-search", (store) => JSON.stringify({
			version: WIRE_VERSION, kind: "activity_search", store, session, query, kinds: [...kinds],
			before_position: before?.position ?? null, before_ordinal: before?.ordinal ?? null, limit: String(limit),
		} satisfies Schemas["ActivitySearchRequest"]))).toString("utf8")) as Schemas["ActivitySearchReply"];
		for (const item of page.items) {
			if (options.signal?.aborted) return;
			yield { ...item, cursor: encodeCursor(item.position, item.ordinal) };
		}
		if (page.next === null) return;
		before = page.next;
	}
}
