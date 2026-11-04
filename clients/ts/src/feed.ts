// The Session feed: `listActivity` is an async iterator over /v1/activity-page
// (D9, D10, D117, A-D117, D134, D168). The Host sends rows with content
// references only, and no cursor type. The client encodes the cursor from a
// row's position and ordinal, and fills `text` from /v1/activity-content, so
// the Host holds no reply buffer for either (D168).
import { setTimeout as sleep } from "node:timers/promises";

import type { Link } from "./sessions.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];
type Row = Schemas["ActivityItem"];

/** The row kinds the Host sends today. */
export const FEED_KINDS = ["admission", "user", "assistant", "call", "tool_result", "hosted_call", "turn_ended", "stop", "sent", "send_failed", "received"] as const;
export type FeedKind = (typeof FEED_KINDS)[number];

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
	/** Never ends: polls for new entries, 250 ms rising to 2 s while idle. */
	follow?: boolean;
	/** Only these kinds, by their wire names. Left out, every kind. */
	kinds?: readonly FeedKind[];
}

/**
 * One feed entry. `kind` and the fields of that kind's row follow in camelCase,
 * as the wire spells them. Rows with text carry it as `text`.
 */
export interface FeedEntry {
	kind: FeedKind;
	/** Pass as `after` to continue after this entry. */
	cursor: string;
	position: string;
	ordinal: string;
	at: string;
	/** The row's text, when it has some and the kind carries it. */
	text?: string;
	/** True when the text is longer than 16 KiB and `text` is absent: use `session.readContent(entry)`. */
	truncated?: boolean;
	/** The text's length in bytes, when the row has text. */
	contentBytes?: string;
	[field: string]: unknown;
}

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
	return name.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());
}

function camelCase(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(camelCase);
	if (value !== null && typeof value === "object") {
		return Object.fromEntries(Object.entries(value).map(([name, inner]) => [camel(name), camelCase(inner)]));
	}
	return value;
}

function isReference(value: unknown): value is Schemas["ActivityItemContent"] {
	return typeof value === "object" && value !== null && "bytes" in value && "sha256" in value;
}

/** Builds an entry from a row, without its text. Returns the content reference when text is to be read. */
function entryOf(row: Row): { entry: FeedEntry; reference: Schemas["ActivityItemContent"] | undefined } {
	const [kind, payload] = Object.entries(row.value)[0] as [FeedKind, Record<string, unknown>];
	const { content, ...rest } = payload;
	const entry: FeedEntry = {
		kind,
		cursor: encodeCursor(row.position, row.ordinal),
		position: row.position,
		ordinal: row.ordinal,
		at: row.at,
		...(camelCase(rest) as object),
	};
	const reference = isReference(content) ? content : undefined;
	const wanted = kind !== "turn_ended" || ENDINGS_WITH_TEXT.has(String(payload.ending));
	if (reference && wanted) entry.contentBytes = reference.bytes;
	return { entry, reference: reference && wanted ? reference : undefined };
}

function activityBody(store: string, session: string, request: { end: string | null; position: string; ordinal: string | null; kinds: readonly FeedKind[] }): string {
	return `{"version":"8","kind":"activity_page","store":${JSON.stringify(store)},"session":${JSON.stringify(session)},"end":${request.end === null ? "null" : JSON.stringify(request.end)},"position":${JSON.stringify(request.position)},"ordinal":${request.ordinal === null ? "null" : JSON.stringify(request.ordinal)},"direction":"forward","kinds":${JSON.stringify(request.kinds)},"limit":"${PAGE_ROWS}"}`;
}

function contentBody(store: string, session: string, entry: { position: string; ordinal: string }): string {
	return `{"version":"8","kind":"activity_content","store":${JSON.stringify(store)},"session":${JSON.stringify(session)},"position":${JSON.stringify(entry.position)},"ordinal":${JSON.stringify(entry.ordinal)}}`;
}

/** The whole text of an entry that has some, however long (D134). */
export async function readContent(link: Link, session: string, entry: { position: string; ordinal: string }): Promise<string> {
	const bytes = await link.exchange("/v1/activity-content", (store) => contentBody(store, session, entry));
	return bytes.toString("utf8");
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
	for (;;) {
		const page = JSON.parse(
			(await link.exchange("/v1/activity-page", (store) => activityBody(store, session, { end: pinnedEnd, position, ordinal, kinds }))).toString("utf8"),
		) as Schemas["ActivityPageReply"];
		for (const row of page.items) {
			const { entry, reference } = entryOf(row);
			if (reference) {
				if (Number(reference.bytes) > INLINE_TEXT_BYTES) {
					entry.truncated = true;
				} else {
					const prefix = await link.exchange("/v1/activity-content", (store) => contentBody(store, session, row), undefined, INLINE_TEXT_BYTES);
					entry.text = prefix.toString("utf8");
				}
			}
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
		if (page.items.length > 0) wait = FIRST_POLL_MS;
		else await sleep(wait);
		if (page.items.length === 0) wait = Math.min(wait * 2, MAX_POLL_MS);
	}
}
