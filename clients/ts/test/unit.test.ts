import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { encodeFrame, startError } from "../src/client.ts";
import { RuiStartError } from "../src/errors.ts";
import { environmentBytes } from "../src/sessions.ts";
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
