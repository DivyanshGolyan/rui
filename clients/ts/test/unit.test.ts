import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { encodeSettings, launchFor, readinessInstance, startError } from "../src/client.ts";
import { pipeSettings, type HostSettings } from "../src/settings.ts";
import { RuiStartError } from "../src/errors.ts";
import { FEED_KINDS, listActivity } from "../src/feed.ts";
import { environmentBytes, Sessions, type Link } from "../src/sessions.ts";
import { ConnectionError, post, WIRE_VERSION } from "../src/transport.ts";

test("the wire version is the one openapi.json describes", () => {
	const document = JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"));
	assert.equal(WIRE_VERSION, document.info.version);
});

function documentFor(settings: HostSettings) {
	const launch = launchFor(settings, "/r");
	try {
		return JSON.parse(launch.document.subarray(4).toString("utf8"));
	} finally {
		launch.document.fill(0);
	}
}

test("a settings document is a big-endian byte length and JSON", () => {
	const document = { store: { sqlite: { dir: "/s/é" } } } satisfies import("../src/wire.ts").components["schemas"]["HostSettings"];
	const bytes = encodeSettings(document);
	try {
		assert.equal(bytes.readUInt32BE(0), Buffer.byteLength(JSON.stringify(document)));
		assert.deepEqual(JSON.parse(bytes.subarray(4).toString("utf8")), document);
	} finally {
		bytes.fill(0);
	}
});

test("settings reach every Adapter without a provider-specific builder", () => {
	const settings: HostSettings = {
		store: { mysql: { url: "mysql://user:password@localhost/db" } },
		providers: { codex: { credentialFile: "/c" }, openai: { endpoint: "https://example.com", key: "key" }, chatgpt: {} },
		network: { caFile: "/trust" },
		tools: { bash: { path: "/bash", timeoutMs: 42 }, mcp: { drift: { url: "http://127.0.0.1:3000/mcp", bearerToken: "secret", callTimeoutMs: 99 } } },
		execution: { activeCapacity: 3, paused: true },
	};
	assert.deepEqual(documentFor(settings), {
		...settings,
		store: { mysql: { url: { value: "mysql://user:password@localhost/db" } } },
		providers: { ...settings.providers, openai: { endpoint: "https://example.com", key: { value: "key" } } },
		tools: { bash: settings.tools?.bash, mcp: { drift: { url: "http://127.0.0.1:3000/mcp", bearerToken: { value: "secret" }, callTimeoutMs: 99 } } },
		interface: { dir: "/r", lifetime: "stdin" },
	});
	assert.equal(settings.providers?.openai?.key, "key", "caller settings stay unchanged");
});

test("interface lifetime defaults to stdin and an explicit choice wins", () => {
	assert.deepEqual(documentFor({}).interface, { dir: "/r", lifetime: "stdin" });
	assert.deepEqual(documentFor({ interface: { dir: "/custom", lifetime: "detached" } }).interface, { dir: "/custom", lifetime: "detached" });
	assert.deepEqual(documentFor({ interface: { dir: null, lifetime: "detached" } }).interface, { dir: "/r", lifetime: "detached" });
	const launch = launchFor({ interface: { lifetime: "detached" } }, "/r");
	assert.equal(launch.detached, true);
	launch.document.fill(0);
});

test("schema-derived codecs cover every secret and OS-byte leaf", () => {
	const schema = JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"));
	const leaves: { path: string[]; kind: string }[] = [];
	// Walk the source schema independently of the generated runtime descriptor.
	function walk(node: any, path: string[]) {
		if (!node || typeof node !== "object") return;
		if (node.$ref) return;
		if (node["x-rui-kind"]) leaves.push({ path, kind: node["x-rui-kind"] });
		for (const child of [...(node.oneOf ?? []), ...(node.anyOf ?? []), ...(node.allOf ?? [])]) walk(child, path);
		for (const [key, child] of Object.entries(node.properties ?? {})) walk(child, [...path, key]);
		walk(node.additionalProperties, [...path, "named-server"]);
	}
	walk(schema.components.schemas.HostSettings, []);
	assert.ok(leaves.some(({ kind }) => kind === "secret"));
	assert.ok(leaves.some(({ kind }) => kind === "bytes"));
	for (const { path, kind } of leaves) {
		function at(value: unknown) {
			return path.reduceRight((field, name) => ({ [name]: field }), value);
		}
		const values = kind === "secret" ? ["literal-secret", { value: "literal-secret" }, { owner: true }, null] : ["/plain", Uint8Array.of(47, 255, 120), { hex: "2fff78" }];
		for (const value of values) {
			const input = at(value) as HostSettings;
			const expected = kind === "secret" && typeof value === "string" ? { value }
				: value instanceof Uint8Array ? { hex: "2fff78" } : value;
			assert.deepEqual(pipeSettings(input), at(expected), path.join("."));
		}
	}
});

test("named secret codecs do not confuse map names with Object prototype properties", () => {
	for (const name of ["constructor", "toString", "__proto__"]) {
		const mcp = Object.fromEntries([[name, { bearerToken: "secret", url: "http://127.0.0.1:1" }]]);
		assert.deepEqual(pipeSettings({ tools: { mcp } }), { tools: { mcp: Object.fromEntries([[name, { bearerToken: { value: "secret" }, url: "http://127.0.0.1:1" }]]) } });
	}
});

test("only explicitly named secret environment sources join the base child environment", () => {
	const selected = "RUI_TS_SELECTED_SECRET";
	const unused = "RUI_TS_UNSELECTED_SECRET";
	const oldSelected = process.env[selected];
	const oldUnused = process.env[unused];
	process.env[selected] = "selected-private-value";
	process.env[unused] = "unselected-private-value";
	try {
		for (const name of [selected, Buffer.from(selected), { hex: Buffer.from(selected).toString("hex") }]) {
			for (const settings of [
				{ providers: { openai: { key: { env: name } } } },
				{ store: { mysql: { url: { env: name } } } },
				{ tools: { mcp: { source: { url: "http://127.0.0.1:1", bearerToken: { env: name } } } } },
			] satisfies HostSettings[]) {
				const launch = launchFor(settings, "/r");
				try {
					assert.equal(launch.env[selected], "selected-private-value");
					assert.equal(launch.env[unused], undefined);
					assert.ok(!launch.document.includes(Buffer.from("selected-private-value")), "environment values stay out of the document");
					assert.deepEqual(Object.keys(launch.env).sort(), ["PATH", "HOME", "TMPDIR", selected].filter((key) => process.env[key] !== undefined).sort());
				} finally {
					launch.document.fill(0);
				}
			}
		}
	} finally {
		if (oldSelected === undefined) delete process.env[selected]; else process.env[selected] = oldSelected;
		if (oldUnused === undefined) delete process.env[unused]; else process.env[unused] = oldUnused;
	}
});

test("environment names preserve reserved keys, Unicode and a UTF-8 BOM byte for byte", () => {
	for (const selected of ["__proto__", "constructor", "toString", "RUI_TS_É", "\uFEFFRUI_TS_BOM"]) {
		const old = process.env[selected];
		process.env[selected] = "selected-private-value";
		try {
			for (const env of [selected, Buffer.from(selected), { hex: Buffer.from(selected).toString("hex") }]) {
				const launch = launchFor({ providers: { openai: { key: { env } } } }, "/r");
				try {
					assert.equal(Object.hasOwn(launch.env, selected), true, selected);
					assert.equal(launch.env[selected], "selected-private-value");
					assert.ok(!Object.hasOwn(launch.env, selected.replace(/^\uFEFF/, "")) || !selected.startsWith("\uFEFF"), "BOM must not select an unreferenced key");
				} finally {
					launch.document.fill(0);
				}
			}
		} finally {
			if (old === undefined) delete process.env[selected]; else process.env[selected] = old;
		}
	}
});

test("non-UTF-8 environment names refuse without selecting a lossy replacement", () => {
	for (const env of [Uint8Array.of(255), { hex: "ff" }]) {
		assert.throws(() => launchFor({ providers: { openai: { key: { env } } } }, "/r"), (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "settings_invalid");
			assert.match(error.message, /providers\.openai\.key\.env:/);
			assert.ok(!error.message.includes("ff"));
			return true;
		});
	}
});

test("presets preserve creation fields and use the existing spec writer", () => {
	const spec = { model: "custom", effort: null, compactAt: 1000, tools: ["bash"] as const, permissionMode: "ask" as const, provider: "openai" as const, workspace: "/w", outputSchema: { type: "object" } };
	assert.deepEqual(documentFor({ presets: { review: spec } }).presets, { review: spec });
	for (const text of ["[]", "false", "not JSON"]) {
		// @ts-expect-error The runtime Host also refuses non-object schemas.
		const invalid = documentFor({ presets: { review: { ...spec, outputSchema: text } } });
		assert.equal(invalid.presets.review.outputSchema, text);
	}
});

test("child readiness accepts exactly one complete fixed leading instance receipt", () => {
	const instance = "a0123456789bcdef".repeat(2);
	const receipt = Buffer.from(`ready instance=${instance} `);
	for (let split = 0; split < receipt.length; split++) {
		assert.equal(readinessInstance(receipt.subarray(0, split)), undefined, `split ${split}`);
		const pending = Buffer.alloc(receipt.length);
		receipt.subarray(0, split).copy(pending);
		receipt.subarray(split).copy(pending, split);
		assert.equal(readinessInstance(pending), instance);
	}
	for (const invalid of [
		`ready instance=${"A".repeat(32)} `,
		`ready instance=${"a".repeat(31)} `,
		`ready instance=${"a".repeat(33)} `,
		`ready store=path\nready instance=${instance} `,
		`not-ready\nready instance=${instance} `,
		`ready instance=${instance} \n`,
	]) assert.equal(readinessInstance(Buffer.from(invalid)), undefined);
	const highBit = Buffer.from(receipt);
	highBit[0] = highBit[0]! | 128;
	assert.equal(readinessInstance(highBit), undefined, "receipt parser must not strip high bits");
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
	// @ts-expect-error The owner accepts only the two lifetime choices, not null.
	launchFor({ interface: { lifetime: null } }, "/r");
	// @ts-expect-error Store Adapters are objects, not the old URL/path field.
	encodeSettings({ store: "/s" });
	// @ts-expect-error Provider CA trust is a PEM filename, never a verification toggle.
	launchFor({ network: { caFile: false } }, "/r");
	new RuiStartError("store_fenced", "refused");
	new RuiStartError("mysql_version", "refused");
	new RuiStartError("mariadb", "refused");
	new RuiStartError("read_only_replica", "refused");
	new RuiStartError("durability_innodb_flush_log_at_trx_commit", "refused");
	new RuiStartError("durability_sync_binlog", "refused");
	new RuiStartError("binlog_statement", "refused");
	new RuiStartError("mysql_unreachable", "refused");
	new RuiStartError("mysql_login", "refused");
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

test("presets and configure encode one spec including loaded tools and output reservation", async () => {
	const spec = { model: "custom", effort: null, compactAt: 1000, tools: ["web_search", "find_tools"], loadedTools: ["find_tools"], outputReservation: 42, permissionMode: "ask" as const, instructions: "rules", outputSchema: { type: "object" } };
	const options = { presets: { review: spec } };
	let configuration: unknown;
	const sessions = new Sessions({ async exchange(_path, build) {
		configuration = JSON.parse(build("/s")).configuration;
		return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "k7m2qx" } }));
	} });
	await sessions.create(spec, { idempotencyKey: "one-spec" });
	const preset = documentFor(options).presets.review;
	assert.deepEqual(configuration, preset);
	assert.deepEqual(preset.loadedTools, ["find_tools"]);
	assert.equal(preset.outputReservation, 42);
	assert.deepEqual(preset.outputSchema, { type: "object" });
});
