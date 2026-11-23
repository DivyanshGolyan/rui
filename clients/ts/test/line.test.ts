import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setImmediate as turn } from "node:timers/promises";
import { test } from "node:test";

import { RuiRequestError } from "../src/errors.ts";
import { Line, LineProtocolError, type LineFrame, type LineHandler } from "../src/line.ts";
import { ConnectionError } from "../src/transport.ts";

const INSTANCE = "a".repeat(32);

function frame(payload: object | string): Buffer {
	const json = Buffer.from(typeof payload === "string" ? payload : JSON.stringify(payload));
	const out = Buffer.alloc(4 + json.length);
	out.writeUInt32BE(json.length, 0);
	json.copy(out, 4);
	return out;
}

/** A Host's line endpoint: `script` decides what each upgrade answers, and `received` records the client's frames. */
async function scriptedHost(t: { after(fn: () => void): void }, script: (socket: Socket) => void, refuse?: { status: number; body: string }) {
	const directory = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-line-")));
	const socketPath = join(directory, "rui.sock");
	const received: Buffer[] = [];
	const server: Server = createServer((_request, response) => {
		response.writeHead(refuse?.status ?? 404, { "content-type": "application/json", "content-length": String(Buffer.byteLength(refuse?.body ?? "{}")) });
		response.end(refuse?.body ?? "{}");
	});
	server.on("upgrade", (request, socket) => {
		assert.equal(request.url, "/v1/line");
		assert.equal(request.headers.upgrade, "rui-line/1");
		assert.equal(request.headers["x-rui-host-instance"], INSTANCE);
		if (refuse) {
			socket.end(`HTTP/1.1 ${refuse.status} Refused\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(refuse.body)}\r\nConnection: close\r\n\r\n${refuse.body}`);
			return;
		}
		socket.on("data", (chunk: Buffer) => received.push(chunk));
		socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: rui-line/1\r\nConnection: Upgrade\r\n\r\n");
		script(socket as Socket);
	});
	server.listen(socketPath);
	await once(server, "listening");
	t.after(() => {
		server.close();
		server.closeAllConnections();
		rmSync(directory, { recursive: true, force: true });
	});
	return { socketPath, received };
}

function recorder() {
	const frames: LineFrame[] = [];
	const closed: { error: Error | undefined }[] = [];
	const handler: LineHandler = {
		frame: (value) => { frames.push(value); },
		closed: (_line, error) => { closed.push({ error }); },
	};
	return { handler, frames, closed };
}

test("the line sends its watched set as one length-prefixed frame and reads the Host's frames in order", { timeout: 5000 }, async (t) => {
	const host = await scriptedHost(t, (socket) => {
		socket.write(frame({ type: "hello", line: 1, instance: INSTANCE }));
		socket.write(frame({ type: "changed", session: "k7m2qx" }));
		socket.write(frame({ type: "resync" }));
		socket.write(frame({ type: "ping" }));
		socket.write(frame({ type: "failed", code: "host_stopping" }));
	});
	const { handler, frames, closed } = recorder();
	const line = await Line.open({ socketPath: host.socketPath, instance: INSTANCE, handler });
	t.after(() => line.close());
	line.watch(["k7m2qx", "09azvw"]);
	await waitFor(() => frames.length === 5);
	assert.deepEqual(frames, [
		{ type: "hello", line: 1, instance: INSTANCE },
		{ type: "changed", session: "k7m2qx" },
		{ type: "resync" },
		{ type: "ping" },
		{ type: "failed", code: "host_stopping" },
	]);
	assert.equal(line.isOpen, true);
	await waitFor(() => Buffer.concat(host.received).length >= 4);
	const bytes = Buffer.concat(host.received);
	const length = bytes.readUInt32BE(0);
	assert.deepEqual(JSON.parse(bytes.subarray(4, 4 + length).toString("utf8")), { type: "watch", sessions: ["k7m2qx", "09azvw"] });
	assert.deepEqual(closed, []);
});

test("frames split across reads and frames inside the upgrade reply decode whole", { timeout: 5000 }, async (t) => {
	const bytes = Buffer.concat([frame({ type: "changed", session: "k7m2qx" }), frame({ type: "ping" })]);
	const host = await scriptedHost(t, (socket) => {
		socket.write(bytes.subarray(0, 3));
		setImmediate(() => socket.write(bytes.subarray(3, 9)));
		setImmediate(() => socket.write(bytes.subarray(9)));
	});
	const { handler, frames } = recorder();
	const line = await Line.open({ socketPath: host.socketPath, instance: INSTANCE, handler });
	t.after(() => line.close());
	await waitFor(() => frames.length === 2);
	assert.deepEqual(frames, [{ type: "changed", session: "k7m2qx" }, { type: "ping" }]);
});

for (const [name, bytes] of [
	["a zero-length frame", Buffer.alloc(4)],
	["a frame above 16 KiB", Buffer.from([0, 0, 0x40, 0x01])],
	["an unknown frame type", frame({ type: "calls" })],
	["a changed frame without a session", frame({ type: "changed" })],
	["a payload that is not JSON", frame("not json")],
] as const) {
	test(`the line ends with LineProtocolError on ${name}`, { timeout: 5000 }, async (t) => {
		const host = await scriptedHost(t, (socket) => {
			socket.write(bytes);
		});
		const { handler, closed } = recorder();
		const line = await Line.open({ socketPath: host.socketPath, instance: INSTANCE, handler });
		await waitFor(() => closed.length === 1);
		assert.ok(closed[0]?.error instanceof LineProtocolError);
		assert.equal(line.isOpen, false);
	});
}

test("a refused upgrade rejects with the Host's refusal code", { timeout: 5000 }, async (t) => {
	const host = await scriptedHost(t, () => {}, { status: 503, body: JSON.stringify({ version: "24", type: "host_unavailable", code: "host_stopping" }) });
	await assert.rejects(Line.open({ socketPath: host.socketPath, instance: INSTANCE, handler: recorder().handler }), (error: unknown) => error instanceof RuiRequestError && error.code === "host_stopping");
});

test("an absent Host socket rejects as a connection error", { timeout: 5000 }, async () => {
	const missing = join(realpathSync(tmpdir()), `rui-ts-line-missing-${process.pid}.sock`);
	await assert.rejects(Line.open({ socketPath: missing, instance: INSTANCE, handler: recorder().handler }), ConnectionError);
});

test("close ends the line once, without an error, and a closed line never sends", { timeout: 5000 }, async (t) => {
	const host = await scriptedHost(t, (socket) => {
		socket.write(frame({ type: "hello", line: 2, instance: INSTANCE }));
	});
	const { handler, closed } = recorder();
	const line = await Line.open({ socketPath: host.socketPath, instance: INSTANCE, handler });
	line.close();
	line.close();
	line.watch(["k7m2qx"]);
	await waitFor(() => closed.length === 1);
	assert.deepEqual(closed, [{ error: undefined }]);
	assert.equal(line.isOpen, false);
	assert.equal(host.received.length, 0);
});

async function waitFor(condition: () => boolean): Promise<void> {
	for (let index = 0; index < 1000 && !condition(); index++) await turn();
	assert.ok(condition(), "the condition was not reached");
}
