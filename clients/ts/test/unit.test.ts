import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { encodeFrame, startError } from "../src/client.ts";
import { RuiStartError } from "../src/errors.ts";
import { listActivity } from "../src/feed.ts";
import { environmentBytes, type Link } from "../src/sessions.ts";
import { ConnectionError, post, WIRE_VERSION } from "../src/transport.ts";

test("the wire version is the one openapi.json describes", () => {
	const document = JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"));
	assert.equal(WIRE_VERSION, document.info.version);
});

test("a launch frame is a big-endian length and the JSON", () => {
	const frame = encodeFrame({ v: 1, store: "/s" });
	const json = '{"v":1,"store":"/s"}';
	assert.equal(frame.readUInt32BE(0), json.length);
	assert.equal(frame.subarray(4).toString("utf8"), json);
});

test("the refusal line becomes a RuiStartError", () => {
	const refusal = startError('{"rui_start_error":{"code":"store_locked","message":"another Host holds this Store"}}\n');
	assert.ok(refusal instanceof RuiStartError);
	assert.equal(refusal.code, "store_locked");
	assert.equal(refusal.message, "another Host holds this Store");
	assert.equal(startError(""), undefined);
	assert.equal(startError("not json\n"), undefined);
});

test("environment entries the Host would refuse are left out, never split", () => {
	const bytes = environmentBytes({ SAFE: "ok\0OTHER=value", "A=B": "x", "": "y", RUI_X: "z", GOOD: "1", ALSO: "two" });
	assert.equal(bytes.toString("utf8"), "GOOD=1\0ALSO=two\0");
});

function pageOf(rows: number): Buffer {
	const items = Array.from({ length: rows }, (_, index) => ({ position: String(index + 1), ordinal: "0", at: "t", value: { stop: {} } }));
	return Buffer.from(JSON.stringify({ items, more: false, end: String(rows) }));
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
			return Buffer.from(JSON.stringify({ items: [], more: false, end: "9" }));
		},
	};
	for await (const entry of listActivity(link, "s", { follow: true, kinds: ["received"], signal: controller.signal })) assert.fail(String(entry));
	assert.equal(bodies.length, 2);
	assert.match(bodies[1] as string, /"position":"9","ordinal":null/);
});
