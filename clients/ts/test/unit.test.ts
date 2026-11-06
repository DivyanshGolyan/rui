import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { encodeFrame, launchFor, startError } from "../src/client.ts";
import { RuiStartError } from "../src/errors.ts";
import { FEED_KINDS, listActivity } from "../src/feed.ts";
import { environmentBytes, Sessions, type Link } from "../src/sessions.ts";
import { ConnectionError, post, WIRE_VERSION } from "../src/transport.ts";

test("the wire version is the one openapi.json describes", () => {
	const document = JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"));
	assert.equal(WIRE_VERSION, document.info.version);
});

test("a launch frame is a big-endian length and the JSON", () => {
	const launch = { v: 1, store: "/s", runtimeDir: "/r", provider: { kind: "openai_key", baseUrl: "https://example.com/v1", key: "test" } } satisfies import("../src/wire.ts").components["schemas"]["LaunchFrame"];
	const frame = encodeFrame(launch);
	const json = JSON.stringify(launch);
	assert.equal(frame.readUInt32BE(0), json.length);
	assert.equal(frame.subarray(4).toString("utf8"), json);
});

test("launch frame carries optional provider CA trust without leaking extra settings", () => {
	const options = { database: "/s", provider: { baseUrl: "https://example.com", key: "key" } };
	assert.deepEqual(launchFor(options, "/r").frame.provider, { kind: "openai_key", ...options.provider });
	const provider = { ...options.provider, caFile: "/fixture/ca.pem", extra: true };
	const frame = launchFor({ ...options, provider }, "/r").frame;
	assert.deepEqual(frame.provider, { kind: "openai_key", ...options.provider, caFile: "/fixture/ca.pem" });
	const decoded = JSON.parse(encodeFrame(frame).subarray(4).toString("utf8"));
	assert.equal(decoded.provider.caFile, "/fixture/ca.pem");
});

test("launch frame carries the MCP servers, an empty list when none are given", () => {
	const options = { database: "/s", provider: { baseUrl: "https://example.com", key: "key" } };
	const tools = [
		{ name: "drift", url: "http://127.0.0.1:3000/mcp", bearerToken: "secret", callTimeoutMs: 42 },
		{ name: "other", url: "http://127.0.0.1:3001/mcp", bearerToken: "secret2", callTimeoutMs: 99 },
	];
	const frame = (extra: object) => launchFor({ ...options, ...extra }, "/r").frame as { mcpServers: unknown };
	assert.deepEqual(frame({}).mcpServers, []);
	assert.deepEqual(frame({ tools: [{ ...tools[0], extra: true }, tools[1]] }).mcpServers, tools);
});

test("launch presets preserve creation fields and decode output schema JSON", () => {
	const spec = { model: "custom", effort: null, compactAt: 1000, tools: ["bash"] as const, permissionMode: "ask" as const, provider: "openai" as const, workspace: "/w", outputSchema: '{"type":"object"}' };
	const options = { database: "/s", provider: { baseUrl: "https://example.com", key: "key" }, presets: { review: spec } };
	const frame = launchFor(options, "/r").frame;
	assert.deepEqual(frame.presets, { review: { ...spec, outputSchema: { type: "object" } } });
	for (const [text, decoded] of [["[]", []], ["false", false], ["not JSON", "not JSON"]] as const) {
		const invalid = launchFor({ ...options, presets: { review: { ...spec, outputSchema: text } } }, "/r").frame;
		assert.deepEqual(JSON.parse(JSON.stringify(invalid)).presets.review.outputSchema, decoded);
	}
});

test("the refusal line becomes a RuiStartError", () => {
	const refusal = startError('{"rui_start_error":{"code":"store_locked","message":"another Host holds this Store"}}\n');
	assert.ok(refusal instanceof RuiStartError);
	assert.equal(refusal.code, "store_locked");
	assert.equal(refusal.message, "another Host holds this Store");
	assert.equal(startError(""), undefined);
	assert.equal(startError("not json\n"), undefined);
	assert.equal(startError("null\n{}\n"), undefined);
	for (const code of ["runtime_dir_unusable", "tool_name_collision", "invalid_preset"] satisfies RuiStartError["code"][]) {
		assert.equal(startError(JSON.stringify({ rui_start_error: { code, message: "refused" } }))?.code, code);
	}
});

test("environment entries the Host would refuse are left out, never split", () => {
	const bytes = environmentBytes({ SAFE: "ok\0OTHER=value", "A=B": "x", "": "y", RUI_X: "z", GOOD: "1", ALSO: "two" });
	assert.equal(bytes.toString("utf8"), "GOOD=1\0ALSO=two\0");
});

function pageOf(rows: number): Buffer {
	const items = Array.from({ length: rows }, (_, index) => ({ position: String(index + 1), ordinal: "0", at: "t", value: { stop: {} } }));
	return Buffer.from(JSON.stringify({ delta: "full", since: null, items, more: false, end: String(rows) }));
}

test("an aborted feed stops between the entries of one page", async () => {
	const link: Link = { exchange: async () => pageOf(2) };
	const controller = new AbortController();
	const feed = listActivity(link, "s", { signal: controller.signal });
	assert.equal((await feed.next()).done, false);
	controller.abort();
	assert.equal((await feed.next()).done, true);
});

test("an aborted feed drops the page its pending read returns", async () => {
	let release = () => {};
	const gate = new Promise<void>((done) => (release = done));
	const link: Link = { exchange: async () => (await gate, pageOf(2)) };
	const controller = new AbortController();
	const pending = listActivity(link, "s", { signal: controller.signal }).next();
	controller.abort();
	release();
	assert.equal((await pending).done, true);
});

test("the feed asks for every kind by default and keeps approval requests when asked for them alone", async () => {
	const bodies: string[] = [];
	const row = { position: "1", ordinal: "1", at: "t", value: { approval_requested: { session: "ch1ld1", action: "7", operation: "2", call_ordinal: "0" } } };
	const link: Link = {
		exchange: async (_path, body) => {
			bodies.push(body("store"));
			return Buffer.from(JSON.stringify({ delta: "full", since: null, items: [row], more: false, end: "1" }));
		},
	};
	assert.equal((await listActivity(link, "s").next()).value?.kind, "approval_requested");
	const only = await listActivity(link, "s", { kinds: ["approval_requested"] }).next();
	assert.ok(only.value && only.value.kind === "approval_requested");
	assert.equal(only.value.sessionId, "ch1ld1");
	assert.deepEqual(JSON.parse(bodies[0] ?? "{}").kinds, [...FEED_KINDS]);
	assert.deepEqual(JSON.parse(bodies[1] ?? "{}").kinds, ["approval_requested"]);
});

async function stalledHost(reply: string): Promise<{ socketPath: string; close: () => void }> {
	const directory = mkdtempSync(join(tmpdir(), "rui-ts-stall-"));
	const socketPath = join(directory, "s");
	const open = new Set<import("node:net").Socket>();
	const server = createServer((socket) => {
		open.add(socket);
		socket.on("error", () => {});
		socket.on("data", () => reply && socket.write(reply));
	});
	await new Promise<void>((ready) => server.listen(socketPath, ready));
	return { socketPath, close: () => { for (const socket of open) socket.destroy(); server.close(); rmSync(directory, { recursive: true, force: true }); } };
}

test("a Host that never answers ends the call after the response wait", async () => {
	const host = await stalledHost("");
	try {
		const started = Date.now();
		await assert.rejects(post({ socketPath: host.socketPath, path: "/v1/x", body: "{}", limits: { responseMs: 200 } }), ConnectionError);
		assert.ok(Date.now() - started < 3_000);
	} finally {
		host.close();
	}
});

test("a reply that stops partway ends the call after the idle budget", async () => {
	const host = await stalledHost("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial");
	try {
		await assert.rejects(post({ socketPath: host.socketPath, path: "/v1/x", body: "{}", limits: { responseMs: 5_000, idleMs: 200 } }), ConnectionError);
	} finally {
		host.close();
	}
});

test("a followed feed resumes from the end of an exhausted page", async () => {
	const bodies: string[] = [];
	const controller = new AbortController();
	const link: Link = {
		exchange: async (_path, build) => {
			bodies.push(build("/s"));
			if (bodies.length === 2) controller.abort();
			return Buffer.from(JSON.stringify({ delta: "full", since: null, items: [], more: false, end: "9", queued: { count: "0" }, work: { state: { kind: "working" } } }));
		},
	};
	for await (const entry of listActivity(link, "s", { follow: true, kinds: ["received"], signal: controller.signal })) assert.fail(String(entry));
	assert.equal(bodies.length, 2);
	assert.match(bodies[1] as string, /"position":"9","ordinal":null/);
});

// These checks are compiled by `npm run check`, but never execute invalid input.
function launchTypeChecks() {
	// @ts-expect-error The Host requires every non-defaulted launch field.
	encodeFrame({ v: 1, store: "/s" });
	// @ts-expect-error Provider CA trust is a PEM filename, never a verification toggle.
	launchFor({ database: "/s", provider: { baseUrl: "https://example.com", key: "key", caFile: false } }, "/r");
	new RuiStartError("store_fenced", "refused");
	new RuiStartError("mysql_version_unsupported", "refused");
	// @ts-expect-error Unknown codes are not launch refusals in the Host enum.
	new RuiStartError("not_a_start_error", "refused");
}

test("activity search follows an empty budget page's next and preserves snippets", async () => {
	const { searchActivity, encodeCursor } = await import("../src/feed.ts");
	const requests: Record<string, unknown>[] = [];
	const hit = { snippet: "Start_Agent", offset: "0", length: "11" };
	const link: Link = { exchange: async (path, body) => {
		assert.equal(path, "/v1/activity-search");
		requests.push(JSON.parse(body("store")));
		return Buffer.from(JSON.stringify(requests.length === 1
			? { items: [], next: { position: "9", ordinal: "2" } }
			: { items: [{ position: "8", ordinal: "1", kind: "call", hits: [hit] }], next: null }));
	} };
	const entries = [];
	for await (const entry of searchActivity(link, "session", "start_agent", { kinds: ["call"], limit: 1 })) entries.push(entry);
	assert.deepEqual(entries, [{ position: "8", ordinal: "1", kind: "call", hits: [hit], cursor: encodeCursor("8", "1") }]);
	assert.equal(requests.length, 2);
	assert.deepEqual(requests[0], { version: WIRE_VERSION, kind: "activity_search", store: "store", session: "session", query: "start_agent", kinds: ["call"], before_position: null, before_ordinal: null, limit: "1" });
	assert.equal(requests[1]?.before_position, "9");
	assert.equal(requests[1]?.before_ordinal, "2");
});

test("activity search validates UTF-8 byte bounds and cancels between hits", async () => {
	const { searchActivity } = await import("../src/feed.ts");
	let calls = 0;
	const link: Link = { exchange: async () => {
		calls++;
		return Buffer.from(JSON.stringify({ items: [{ position: "1", ordinal: "0", kind: "user", hits: [] }, { position: "1", ordinal: "1", kind: "user", hits: [] }], next: null }));
	} };
	for (const query of ["", "é".repeat(129), "\ud800"]) await assert.rejects(searchActivity(link, "s", query).next(), RangeError);
	assert.equal(calls, 0);
	const controller = new AbortController();
	const iterator = searchActivity(link, "s", "é".repeat(128), { signal: controller.signal });
	assert.equal((await iterator.next()).done, false);
	controller.abort();
	assert.equal((await iterator.next()).done, true);
});

test("session summaries preserve both parent references and top-level nulls", async () => {
	const link: Link = {
		exchange: async () => Buffer.from(JSON.stringify({
			sessions: [
				{ reference: "p33rs1", label: "caller", work: { state: { kind: "idle" } }, archive_state: "active", parent: null },
				{ reference: "k7m2qx", label: "child", work: { state: { kind: "pending" } }, archive_state: "archiving", parent: "p33rs1" },
			],
			next: null,
		})),
	};
	assert.deepEqual(await new Sessions(link).list(), [
		{ id: "k7m2qx", label: "child", state: "pending", archiveState: "archiving", parent: "p33rs1" },
		{ id: "p33rs1", label: "caller", state: "idle", archiveState: "active", parent: null },
	]);
});


test("approval and ending feed entries expose the child sessionId", async () => {
	for (const value of [
		{ approval_requested: { session: "ch1ld1", action: "7", operation: "2", call_ordinal: "0" } },
		{ turn_ended: { session: "ch1ld1", turn: "3", operation: "2", ending: "stopped", code: "cancelled", content: null } },
	]) {
		const link: Link = { exchange: async () => Buffer.from(JSON.stringify({ delta: "full", since: null, items: [{ position: "1", ordinal: "0", at: "1", value }], more: false, end: "1" })) };
		const entry = (await listActivity(link, "p4rent").next()).value;
		assert.ok(entry && (entry.kind === "approval_requested" || entry.kind === "turn_ended"));
		const sessionId: string = entry.sessionId;
		assert.equal(sessionId, "ch1ld1");
		assert.equal("session" in entry, false);
	}
});
