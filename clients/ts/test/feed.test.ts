import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError, RuiUnavailableError } from "../src/errors.ts";
import { decodeCursor, listActivity, type FeedEntry } from "../src/feed.ts";
import { Session, type Link } from "../src/sessions.ts";
import { scriptedLink } from "./scripted-line.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import { ENDING_SIGN } from "../src/turn-endings.ts";
import type { components } from "../src/wire.ts";

type Schemas = components["schemas"];

function narrowed(entry: FeedEntry): void {
	switch (entry.kind) {
		case "admission": case "user": case "received": {
			const state: "queued" | "applied" | "excluded" = entry.state;
			const admitted: string = entry.admittedAt;
			const sender: Schemas["NamedPeer"] | null = entry.sender;
			const text: string | undefined = entry.text;
			void [state, admitted, sender, text];
			break;
		}
		case "assistant": {
			const final: boolean = entry.final;
			void final;
			break;
		}
		case "call": {
			const ordinal: string = entry.callOrdinal;
			const description: string | null = entry.description;
			const tool: string | null = entry.tool;
			const server: string | null = entry.server;
			void [description, tool, server];
			const fields: [Schemas["ContentValue"], Schemas["ContentValue"], Schemas["ContentValue"]] = entry.fields;
			// @ts-expect-error Only top-level camelCase keys are exposed.
			void entry.call_ordinal;
			// @ts-expect-error Calls do not have the text-bearing row's extras.
			void entry.text;
			void [ordinal, fields];
			break;
		}
		case "tool_result": case "hosted_call": {
			const position: string | null = entry.presentation.publication_position;
			// @ts-expect-error Nested keys keep their generated wire spelling.
			void entry.presentation.publicationPosition;
			void position;
			break;
		}
		case "turn_ended": {
			const sessionId: string = entry.sessionId;
			// @ts-expect-error The wire session field is exposed as sessionId.
			void entry.session;
			const ending: "done" | "context_full" | "provider_refused" | "out_of_quota" | "provider_unavailable" | "stopped" | "interrupted" | "failed" = entry.ending;
			const content: Schemas["ContentValue"] | null = entry.content;
			void [sessionId, ending, content];
			break;
		}
		case "stop": {
			const completion: "pending" | "completed" = entry.completion;
			void completion;
			break;
		}
		case "approval_requested": {
			const sessionId: string = entry.sessionId;
			// @ts-expect-error The wire session field is exposed as sessionId.
			void entry.session;
			const action: string = entry.action;
			const ordinal: string = entry.callOrdinal;
			const description: string | null = entry.description;
			const tool: string | null = entry.tool;
			const server: string | null = entry.server;
			void [description, tool, server];
			// @ts-expect-error Other kinds' fields must not be accepted.
			void entry.final;
			void [sessionId, action, ordinal];
			break;
		}
		case "session_changed": {
			const field: "provider" | "model" | "instructions" | "tools" | "loaded_tools" | "permission_mode" | "output_schema" | "compaction_trigger" | "output_reservation" | "reasoning_effort" | "reasoning_effort_refused" | "label" | "app_tools" = entry.field;
			const providerText: string | null = entry.providerText;
			void [field, providerText];
			break;
		}
		case "compacted": {
			const dropped: string = entry.dropped;
			void dropped;
			break;
		}
		case "model_call": {
			const model: string = entry.model;
			const served: string | null = entry.servedModel;
			const input: string | null = entry.inputTokens;
			const output: string | null = entry.outputTokens;
			const cached: string | null = entry.cachedTokens;
			const latency: string | null = entry.latencyMs;
			const first: string | null = entry.firstEventMs;
			const status: string = entry.status;
			const attempts: string = entry.attempts;
			// @ts-expect-error Model calls do not expose message text.
			void entry.text;
			void [model, served, input, output, cached, latency, first, status, attempts];
			break;
		}
		case "instruction": {
			const turn: string | null = entry.turn;
			const revision: string | null = entry.revision;
			void [turn, revision];
			break;
		}
		case "skill": {
			const admission: string = entry.admission;
			const turn: string = entry.turn;
			const ordinal: string = entry.ordinal;
			const name: string = entry.name;
			void [admission, turn, ordinal, name];
			break;
		}
		default: {
			const exhaustive: never = entry;
			void exhaustive;
		}
	}
}

test("feed entry types narrow to each generated kind", () => { void narrowed; });

test("TS-17 a failed Turn ending carries its report text inline and no other ending does", async () => {
	const content = { type: "text", bytes: "6", sha256: "hash" } as const;
	const endings = Object.keys(ENDING_SIGN) as (keyof typeof ENDING_SIGN)[];
	const rows = endings.map((ending, index) => ({
		position: String(index + 1), ordinal: "0", at: "1",
		value: { turn_ended: { session: "s", turn: "1", operation: "1", ending, code: ending, content } },
	}));
	const link: Link = { exchange: async (path) => path === "/v1/activity-content" ? Buffer.from("report") : Buffer.from(JSON.stringify({ work: { actions: { stop: false, interrupt: null, decide: null } }, delta: "full", since: null, items: rows, more: false, end: String(rows.length) })) };
	const entries: FeedEntry[] = [];
	for await (const entry of listActivity(link, "s")) entries.push(entry);
	assert.equal(entries.length, endings.length);
	for (const [index, ending] of endings.entries()) {
		const entry = entries[index];
		assert.ok(entry?.kind === "turn_ended");
		const failed = ENDING_SIGN[ending] === "failed";
		assert.equal(entry.text, failed ? "report" : undefined, ending);
		assert.equal(entry.contentBytes, failed ? "6" : undefined, ending);
	}
	// The failed endings include the two the client once left without text.
	assert.deepEqual(endings.filter((ending) => ENDING_SIGN[ending] === "failed"),
		["context_full", "provider_refused", "out_of_quota", "provider_unavailable", "failed"]);
});

test("feed camelCases only row keys, preserving nested wire values and content references", async () => {
	const presentation = { line: { before: "tool", peer: null, after: null }, code: "succeeded", sign: "finished", publication_position: "7" };
	const content = { type: "text", bytes: "2", sha256: "hash" } as const;
	const hostedAction = { kind: "search", targets: [content, { type: "text", bytes: "3", sha256: "other" }], targets_total: "2", pattern: null } as const;
	const rows = [
		{ position: "1", ordinal: "0", at: "1", value: { tool_result: { content, presentation } } },
		{ position: "2", ordinal: "0", at: "1", value: { hosted_call: { presentation, action: hostedAction } } },
		{ position: "3", ordinal: "0", at: "1", value: { approval_requested: { session: "ch1ld1", action: "8", operation: "9", call_ordinal: "10" } } },
	];
	const link: Link = { exchange: async (path) => path === "/v1/activity-content" ? Buffer.from("ok") : Buffer.from(JSON.stringify({ work: { actions: { stop: false, interrupt: null, decide: null } }, delta: "full", since: null, items: rows, more: false, end: "3" })) };
	const entries = [];
	for await (const entry of listActivity(link, "s")) entries.push(entry);
	assert.ok(entries[0]?.kind === "tool_result");
	assert.deepEqual(entries[0].presentation, presentation);
	assert.deepEqual(entries[0].content, content);
	assert.equal(entries[0].text, "ok");
	assert.equal(entries[0].contentBytes, "2");
	assert.ok(entries[1]?.kind === "hosted_call");
	assert.deepEqual(entries[1].presentation, presentation);
	assert.deepEqual(entries[1].action, hostedAction);
	assert.ok(entries[2]?.kind === "approval_requested");
	assert.equal(entries[2].callOrdinal, "10");
	assert.equal(entries[2].sessionId, "ch1ld1");
	assert.equal("session" in entries[2], false);
	assert.equal("call_ordinal" in entries[2], false);
});

for (const follow of [false, true]) {
	test(`${follow ? "following" : "bounded"} pagination never reuses a token while pages remain unread`, async () => {
		const requests: Schemas["ActivityPageRequest"][] = [];
		const controller = new AbortController();
		const exchange: Link["exchange"] = async (_path, body) => {
			requests.push(JSON.parse(body("store")) as Schemas["ActivityPageRequest"]);
			const first = requests.length === 1;
			const position = first ? "2" : "3";
			return Buffer.from(JSON.stringify({ delta: "full", since: "token", more: first, end: "9",
				items: [{ position, ordinal: "1", at: "1", value: { stop: { key: "k", turn: null, cutoff: "1", completion: "completed" } } }],
				aggregates: { as_of: "9", call_activity: { total: "0", entries: [] }, queued: { count: "0" } }, work: { actions: { stop: false, interrupt: null, decide: null }, state: { kind: "working" } },
			}));
		};
		// A following traversal needs a line; its second page is owed by the first page's `more`, not by a nudge.
		const link: Link = follow ? scriptedLink(exchange).link : { exchange };
		const feed = listActivity(link, "k7m2qx", { follow, signal: controller.signal });
		try {
			assert.equal((await feed.next()).value?.position, "2");
			assert.equal((await feed.next()).value?.position, "3");
			assert.equal(requests.length, 2);
			assert.deepEqual(requests.map((request) => ({ position: request.position, ordinal: request.ordinal, end: request.end, since: "since" in request ? request.since : undefined })), [
				{ position: "0", ordinal: null, end: null, since: undefined },
				{ position: "2", ordinal: "1", end: follow ? null : "9", since: undefined },
			]);
		} finally {
			controller.abort();
			await feed.return(undefined);
		}
	});
}


test("a refused effort change retains its revision and inline provider text", async () => {
    const row = { position: "4", ordinal: "0", at: "9", value: { session_changed: { revision: "2", field: "reasoning_effort_refused", provider_text: "unsupported_value: high is not supported" } } };
    const link: Link = { exchange: async (path) => {
        assert.equal(path, "/v1/activity-page");
        return Buffer.from(JSON.stringify({ work: { actions: { stop: false, interrupt: null, decide: null } }, delta: "full", since: null, items: [row], more: false, end: "4" }));
    } };
    const entries = [];
    for await (const entry of listActivity(link, "ses123")) entries.push(entry);
    assert.equal(entries.length, 1);
    assert.equal(entries[0]?.kind, "session_changed");
    if (entries[0]?.kind === "session_changed") {
        assert.equal(entries[0].field, "reasoning_effort_refused");
        assert.equal(entries[0].revision, "2");
        assert.equal(entries[0].providerText, "unsupported_value: high is not supported");
    }
});


test("readContent names a hosted row's exact text by its field and sends no field otherwise", async () => {
	const bodies: Schemas["ActivityContentRequest"][] = [];
	const link: Link = { exchange: async (_path, build) => {
		const body = JSON.parse(build("store")) as Schemas["ActivityContentRequest"];
		bodies.push(body);
		return Buffer.from(body.field === "1" ? "second" : "first");
	} };
	const session = new Session(link, "s");
	const entry = { position: "5", ordinal: "0" };
	assert.equal(await session.readContent(entry), "first");
	assert.equal(await session.readContent(entry, { field: 0 }), "first");
	assert.equal(await session.readContent(entry, { field: 1 }), "second");
	assert.deepEqual(await session.readContentBytes(entry, { field: 1 }), Buffer.from("second"));
	assert.deepEqual(bodies.map((body) => body.field), [undefined, "0", "1", "1"]);
});

test("call and approval mapping preserves saved facts and readContent opens original JSON", async () => {
    const facts = { description: "Fetch saved page", tool: "fetch_page", server: "docs" };
    const reference = { type: "text", bytes: "2", sha256: "hash" } as const;
    const rows: Schemas["ActivityItem"][] = [
        { position: "1", ordinal: "0", at: "1", value: { call: { operation: "2", turn: "1", call_ordinal: "0", action: "3", rejection: null, fields: [reference, reference, reference], ...facts } } },
        { position: "2", ordinal: "0", at: "1", value: { call: { operation: "2", turn: "1", call_ordinal: "1", action: "4", rejection: null, fields: [reference, reference, reference], description: "Print saved line", tool: "bash", server: null } } },
        { position: "1", ordinal: "1", at: "1", value: { approval_requested: { session: "ch1ld1", operation: "2", call_ordinal: "0", action: "3", ...facts } } },
    ];
    const original = '{ "url": "https://example.test", "rui_call_description": "Fetch saved page" }';
    const reads: unknown[] = [];
    const link: Link = { exchange: async (path, build) => {
        if (path === "/v1/activity-content") {
            reads.push(JSON.parse(build("/store")));
            return Buffer.from(original);
        }
        return Buffer.from(JSON.stringify({ work: { actions: { stop: false, interrupt: null, decide: null } }, delta: "full", since: null, items: rows, more: false, end: "2" }));
    } };
    const session = new Session(link, "r00t00");
    const entries: FeedEntry[] = [];
    for await (const entry of session.listActivity()) entries.push(entry);
    assert.equal(reads.length, 0, "inline call details require no argument fetch");
    for (const index of [0, 2]) {
        const entry = entries[index];
        assert.ok(entry?.kind === "call" || entry?.kind === "approval_requested");
        assert.deepEqual({ description: entry.description, tool: entry.tool, server: entry.server }, facts);
        assert.equal(await session.readContent(entry), original);
    }
    assert.equal(entries[1]?.kind, "call");
    if (entries[1]?.kind === "call") assert.equal(entries[1].server, null);
    assert.deepEqual(reads.map((read) => (read as { ordinal: string }).ordinal), ["0", "1"]);
});


test("interrupt remembers the last feed page target on its own handle", async () => {
	let target: { turn: string; operation: string } | null = { turn: "8", operation: "21" };
	const requests: string[] = [];
	const session = new Session({ async exchange(path, build) {
		requests.push(path);
		if (path === "/v1/activity-page") return Buffer.from(JSON.stringify({
			delta: "full", items: [], more: false, end: "0", since: null,
			work: { actions: { stop: false, decide: null, interrupt: target } },
		}));
		assert.deepEqual(JSON.parse(build("store")).target, { session: "s", turn: "8", operation: "21" });
		return Buffer.from(JSON.stringify({ answer: { status: "accepted" } }));
	} }, "s");
	for await (const _entry of session.listActivity()) { /* drain */ }
	await session.interrupt({ key: "feed-key" });
	target = null;
	for await (const _entry of session.listActivity()) { /* drain */ }
	await session.interrupt();
	assert.deepEqual(requests, ["/v1/activity-page", "/v1/control/model-interruption", "/v1/activity-page"]);
});


test("feed observations belong to the handle that read them", async () => {
	const paths: string[] = [];
	const link: Link = { async exchange(path) {
		paths.push(path);
		return Buffer.from(JSON.stringify({ delta: "full", items: [], more: false, end: "0", since: null,
			work: { actions: { stop: false, decide: null, interrupt: { turn: "2", operation: "3" } } } }));
	} };
	const reader = new Session(link, "s");
	const other = new Session(link, "s");
	for await (const _entry of reader.listActivity()) { /* drain */ }
	await other.interrupt();
	assert.deepEqual(paths, ["/v1/activity-page"]);
});

test("TS-7 feed parts entries", async () => {
	const image = Buffer.from([0, 255, 42, 128]);
	const owners = [{ message: "17" }, { action: "42" }];
	const requests: { path: string; body: Record<string, unknown>; limits: unknown }[] = [];
	const text = { type: "text", bytes: "2", sha256: "text-hash" };
	const fill = "é".repeat(8190);
	const parts = [
		{ ordinal: "0", type: "text", bytes: "2", sha256: "a" },
		{ ordinal: "1", type: "text", bytes: "16385", sha256: "b" },
		{ ordinal: "2", type: "text", bytes: "16380", sha256: "c" },
		{ ordinal: "3", type: "image", mime: "image/webp", width: "12", height: "34", name: "cat.webp", bytes: "4", sha256: "d" },
		{ ordinal: "4", type: "text", bytes: "2", sha256: "e" },
		{ ordinal: "5", type: "text", bytes: "1", sha256: "f" },
	];
	const kinds = ["user", "tool_result"];
	const rows = [
		{ position: "1", ordinal: "0", at: "1", value: { user: { content: text } } },
		...owners.map((owner, i) => ({ position: String(i + 2), ordinal: "0", at: "1", value: { [kinds[i]!]: { content: { type: "parts", bytes: "99", sha256: "manifest", owner } } } })),
	];
	let failParts = false;
	let onPart: (() => void) | undefined;
	const link: Link = { async exchange(path, build, _environment, limits) {
		const body = JSON.parse(build("store"));
		requests.push({ path, body, limits });
		if (path === "/v1/activity-page") return Buffer.from(JSON.stringify({ work: { actions: { stop: false, interrupt: null, decide: null } }, delta: "full", since: null, items: rows, more: false, end: "3" }));
		if (path === "/v1/activity-content") {
			if (body.position !== "1") throw new RuiRequestError("activity_unavailable", "ContentIsParts");
			return Buffer.from("ok");
		}
		if (path === "/v1/public-parts") {
			if (failParts) throw new RuiRequestError("parts_unavailable", "ContentNotFound");
			return Buffer.from(JSON.stringify({ value: { type: "parts", bytes: "99", sha256: "manifest", owner: body.owner }, parts }));
		}
		assert.equal(path, "/v1/public-part-content");
		assert.equal(body.session, "s");
		assert.equal(body.start, "0");
		assert.equal(body.stream, true);
		onPart?.();
		if (body.part === "0" || body.part === "4") return Buffer.from("hi");
		if (body.part === "1") return Buffer.alloc(16385, 121);
		if (body.part === "2") return Buffer.from(fill);
		if (body.part === "5") return Buffer.from("z");
		assert.equal(body.part, "3");
		return image;
	} };
	const session = new Session(link, "s");
	const entries: FeedEntry[] = [];
	for await (const entry of session.listActivity()) entries.push(entry);
	assert.ok(entries[0]?.kind === "user");
	assert.equal(entries[0].text, "ok");
	await assert.rejects(session.readPart(entries[0], 0), TypeError);
	for (const [index, owner] of owners.entries()) {
		const entry = entries[index + 1];
		assert.ok(entry && (entry.kind === "user" || entry.kind === "tool_result"));
		assert.equal(entry.contentBytes, "99");
		assert.equal("text" in entry, false);
		// Inline text stops at 16 KiB for the entry: 2 + 16380 + 2 bytes fit, the last byte does not.
		assert.deepEqual(entry.parts, [
			{ ordinal: 0, type: "text", bytes: "2", sha256: "a", text: "hi" },
			{ ordinal: 1, type: "text", bytes: "16385", sha256: "b", truncated: true },
			{ ordinal: 2, type: "text", bytes: "16380", sha256: "c", text: fill },
			{ ordinal: 3, type: "image", mime: "image/webp", width: 12, height: 34, name: "cat.webp", bytes: "4", sha256: "d" },
			{ ordinal: 4, type: "text", bytes: "2", sha256: "e", text: "hi" },
			{ ordinal: 5, type: "text", bytes: "1", sha256: "f", truncated: true },
		]);
		assert.deepEqual(await session.readPart(entry, 3), image);
		assert.deepEqual(requests.at(-1)?.limits, { max: 1024 * 1024 * 1024 });
		assert.deepEqual(await session.readPart(entry, 1), Buffer.alloc(16385, 121));
		await assert.rejects(session.readPart(entry, -1), RangeError);
		await assert.rejects(session.readContent(entry), { name: "ContentIsPartsError", message: /readPart/ });
		await assert.rejects(session.readContentBytes(entry), { name: "ContentIsPartsError", message: /readPart/ });
		// The Host decides, so an entry without its content value is refused the same way.
		await assert.rejects(session.readContent({ position: entry.position, ordinal: entry.ordinal }), { name: "ContentIsPartsError" });
		assert.ok(requests.some((request) => request.path === "/v1/public-parts" && JSON.stringify(request.body.owner) === JSON.stringify(owner)));
	}
	assert.equal(requests.filter((request) => request.path === "/v1/public-parts").length, 2);
	// The feed reads no bytes of a truncated part: both reads of part 1 are readPart's.
	assert.equal(requests.filter((request) => request.path === "/v1/public-part-content" && request.body.part === "1").length, 2);
	assert.equal(requests.filter((request) => request.path === "/v1/public-part-content" && request.body.part === "5").length, 0);

	// An abort during an entry's parts stops before the next part is read.
	const abort = new AbortController();
	const before = requests.length;
	onPart = () => abort.abort();
	const aborted: FeedEntry[] = [];
	for await (const entry of session.listActivity({ signal: abort.signal })) aborted.push(entry);
	onPart = undefined;
	assert.equal(aborted.length, 1);
	assert.deepEqual(requests.slice(before).filter((request) => request.path === "/v1/public-part-content").map((request) => request.body.part), ["0"]);

	// A failing parts list rejects the feed at that entry, after the entries before it.
	failParts = true;
	const seen: FeedEntry[] = [];
	await assert.rejects((async () => { for await (const entry of session.listActivity()) seen.push(entry); })(), { code: "ContentNotFound" });
	assert.equal(seen.length, 1);
});
