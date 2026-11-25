
import type { InterruptTarget, Link, ServedWork } from "./sessions.ts";
import { ContentIsPartsError, RuiRequestError, RuiUnavailableError } from "./errors.ts";
import { listParts, readPartBytes, type ContentValue, type Part } from "./parts.ts";
import { WIRE_VERSION } from "./transport.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];
export function servedWork(work: Pick<Schemas["SessionWork"], "actions">): ServedWork {
	if (!work || !work.actions ||
		typeof work.actions.stop !== "boolean" || !("interrupt" in work.actions) || !("decide" in work.actions) ||
		(work.actions.decide !== null && typeof work.actions.decide !== "string") ||
		(work.actions.interrupt !== null && (typeof work.actions.interrupt !== "object" ||
			typeof work.actions.interrupt.turn !== "string" || typeof work.actions.interrupt.operation !== "string"))) {
		throw new Error("Invalid work reply: missing served facts");
	}
	return { canStop: work.actions.stop,
		decide: work.actions.decide, interruptTarget: work.actions.interrupt };
}


type Row = Schemas["ActivityItem"];

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
	"model_call",
	"instruction",
	"skill",
] as const satisfies readonly WireKind[];
export type FeedKind = (typeof FEED_KINDS)[number];
const complete: [Exclude<WireKind, FeedKind>] extends [never] ? true : never = true;
void complete;

/** Entry text is inline up to this many bytes (D168). */
export const INLINE_TEXT_BYTES = 16 * 1024;
const PAGE_ROWS = 16;
const ENDINGS_WITH_TEXT = new Set(["provider_refused", "out_of_quota", "failed"]);

/** Options for following a Session's feed on the client's line. */
export interface WatchOptions {
	/** The `cursor` of the last entry read. Left out, the feed starts at its beginning. */
	after?: string;
	/** Only these kinds, by their wire names. Left out, every kind. */
	kinds?: readonly FeedKind[];
	/** Ends the iterator, even while it waits for new entries: a pending `next()` then resolves as done. */
	signal?: AbortSignal;
}

export interface ListActivityOptions extends WatchOptions {
	/** Follows new entries through `watch`, so the wait ends on the Host's nudges, not on a timer. */
	follow?: boolean;
}

type CamelKey<Key extends string> = Key extends `${infer Head}_${infer Tail}` ? `${Head}${Capitalize<CamelKey<Tail>>}` : Key;
type CamelRow<Payload> = { [Key in keyof Payload as Key extends "session" ? "sessionId" : Key extends string ? CamelKey<Key> : Key]: Payload[Key] };

type EntryText = {
	/** The row's text, when this kind carries it and it fits inline. */
	text?: string;
	/** Text exceeds 16 KiB: use `session.readContent(entry)`. */
	truncated?: boolean;
	/** The value's length in bytes when this kind carries one: the text's length, or the manifest's for a parts value. */
	contentBytes?: string;
	/** Certified parts, in order, when the content is a parts value. */
	parts?: Part[];
};

type EntryFromRow<R extends Row> = R extends Row ? {
	[Kind in keyof R["value"]]: Omit<R, "value"> & { kind: Kind; cursor: string }
		& CamelRow<R["value"][Kind]>
		& ("content" extends keyof R["value"][Kind] ? EntryText : {});
}[keyof R["value"]] : never;

/** A discriminated wire-row union with top-level camelCase fields and an opaque continuation `cursor`.
 * `call` and `approval_requested` carry saved `description`, `tool` and `server`;
 * `readContent` opens their original arguments JSON.
 * `session_changed` uses `reasoning_effort_refused` and inline `providerText` for a refused effort change.
 */
export type FeedEntry = EntryFromRow<Row>;

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

function contentOf(payload: Record<string, unknown>): ContentValue | undefined {
	const value = payload.content;
	if (typeof value !== "object" || value === null || !("type" in value)) return undefined;
	return value.type === "text" || value.type === "parts" ? value as ContentValue : undefined;
}

function entryOf(row: Row): { entry: FeedEntry; reference: Schemas["ContentValue"] | undefined } {
	const [kind, payload] = Object.entries(row.value)[0] as [FeedKind, Record<string, unknown>];
	const reference = contentOf(payload);
	const wanted = kind !== "turn_ended" || ENDINGS_WITH_TEXT.has(String(payload.ending));
	const entry = {
		kind,
		cursor: encodeCursor(row.position, row.ordinal),
		position: row.position,
		ordinal: row.ordinal,
		at: row.at,
		...camelCase(payload),
		...(reference && wanted ? { contentBytes: reference.bytes } : {}),
	} as FeedEntry;
	return { entry, reference: reference && wanted ? reference : undefined };
}

function activityBody(store: string, session: string, request: { end: string | null; position: string; ordinal: string | null; kinds: readonly FeedKind[]; since: string | null }): string {
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
		...(request.since === null ? {} : { since: request.since }),
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

const MAX_CONTENT_BYTES = 1024 * 1024 * 1024;

/** The Host owns the rule: its text route refuses a parts value as `ContentIsParts`. */
export async function readContentBytes(link: Link, session: string, entry: { position: string; ordinal: string }): Promise<Buffer> {
	try {
		return await link.exchange("/v1/activity-content", (store) => contentBody(store, session, entry), undefined, { max: MAX_CONTENT_BYTES });
	} catch (error) {
		if (error instanceof RuiRequestError && error.code === "ContentIsParts") throw new ContentIsPartsError();
		throw error;
	}
}

export async function readContent(link: Link, session: string, entry: { position: string; ordinal: string }): Promise<string> {
	return (await readContentBytes(link, session, entry)).toString("utf8");
}

/** A page request: the next row's cursor, the `since` token of the last full reply, and the kinds. `end` pins a bounded traversal. */
export interface PageRequest {
	end: string | null;
	position: string;
	ordinal: string | null;
	since: string | null;
	kinds: readonly FeedKind[];
}

export async function readPage(link: Link, session: string, request: PageRequest): Promise<Schemas["ActivityPageReply"]> {
	const reply = await link.exchange("/v1/activity-page", (store) => activityBody(store, session, request));
	return JSON.parse(reply.toString("utf8")) as Schemas["ActivityPageReply"];
}

function kindsOf(kinds: readonly FeedKind[] | undefined): readonly FeedKind[] {
	return kinds === undefined ? FEED_KINDS : FEED_KINDS.filter((kind) => kinds.includes(kind));
}

function startOf(after: string | undefined): { position: string; ordinal: string | null } {
	return after === undefined ? { position: "0", ordinal: null } : decodeCursor(after);
}

/** One page's rows as entries, with their inline content read in order. Stops at an abort. */
async function* entriesOf(link: Link, session: string, items: readonly Row[], signal: AbortSignal | undefined): AsyncGenerator<FeedEntry, void, undefined> {
	for (const row of items) {
		if (signal?.aborted) return;
		const { entry, reference } = entryOf(row);
		if (reference && "content" in entry) {
			if (reference.type === "parts") {
				entry.parts = await listParts(link, session, reference.owner);
				// One entry inlines at most INLINE_TEXT_BYTES across its Text parts, as a text entry does.
				let inline = INLINE_TEXT_BYTES;
				for (const part of entry.parts) {
					if (part.type !== "text") continue;
					if (signal?.aborted) return;
					const bytes = Number(part.bytes);
					if (bytes > inline) {
						part.truncated = true;
						continue;
					}
					inline -= bytes;
					part.text = (await readPartBytes(link, session, reference.owner, part.ordinal, { prefix: INLINE_TEXT_BYTES })).toString("utf8");
				}
			} else if (Number(reference.bytes) > INLINE_TEXT_BYTES) {
				entry.truncated = true;
			} else {
				const prefix = await link.exchange("/v1/activity-content", (store) => contentBody(store, session, row), undefined, { prefix: INLINE_TEXT_BYTES });
				entry.text = prefix.toString("utf8");
			}
		}
		if (signal?.aborted) return;
		yield entry;
	}
}

/**
 * Follows a Session's feed on the client's one line: yields each new row once, in order. Each nudge for the Session reads
 * from this iterator's cursor (`Follows`); an idle Session makes no reads until the Host nudges it.
 */
export async function* watchActivity(link: Link, session: string, options: WatchOptions = {}, observe?: (target: InterruptTarget | null) => void): AsyncGenerator<FeedEntry, void, undefined> {
	const follows = link.follows;
	if (!follows) throw new RuiUnavailableError("this client has no line to follow a Session on");
	const watcher = follows.join(session, { ...startOf(options.after), since: null }, kindsOf(options.kinds));
	try {
		for (;;) {
			const page = await watcher.take(options.signal);
			if (page === undefined) return;
			observe?.(servedWork(page.work).interruptTarget);
			yield* entriesOf(link, session, page.items, options.signal);
		}
	} finally {
		follows.leave(watcher);
	}
}

/** The Session's feed from `after` to its current end, or with `follow`, `watchActivity`. */
export async function* listActivity(link: Link, session: string, options: ListActivityOptions = {}, observe?: (target: InterruptTarget | null) => void): AsyncGenerator<FeedEntry, void, undefined> {
	if (options.follow) {
		yield* watchActivity(link, session, options, observe);
		return;
	}
	const kinds = kindsOf(options.kinds);
	let { position, ordinal } = startOf(options.after);
	let end: string | null = null;
	while (!options.signal?.aborted) {
		const page = await readPage(link, session, { end, position, ordinal, since: null, kinds });
		if (page.delta !== "full") throw new Error("the Host answered not_modified to a request with no token");
		observe?.(servedWork(page.work).interruptTarget);
		yield* entriesOf(link, session, page.items, options.signal);
		if (!page.more) return;
		end = page.end;
		const last = page.items.at(-1);
		if (last) {
			position = last.position;
			ordinal = last.ordinal;
		}
	}
}

export interface SearchActivityOptions {
	/** Resume before this search entry's cursor. */
	before?: string;
	kinds?: readonly FeedKind[];
	limit?: number;
	signal?: AbortSignal;
}

export type ActivitySearchEntry = Schemas["ActivitySearchReply"]["items"][number] & { cursor: string };

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
