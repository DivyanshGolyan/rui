import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiRequestError, RuiStoreFailedError, RuiUnavailableError, type HostSettings } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";

// A scripted Host. Each spawn is one attempt and takes the next plan, so a restart meets its own steps. A step answers
// one non-readiness request: a reply, a reply that then ends the Host, a fence line (with or without a later reply), a
// plain exit, a held request released by SIGUSR2, or a fence line written long after the connection drops.
type Step =
	| { kind: "reply"; status: number; body: string }
	| { kind: "reply_then_exit"; status: number; body: string }
	| { kind: "reply_then_fence"; status: number; body: string }
	| { kind: "hold"; status: number; body: string }
	| { kind: "fence" }
	| { kind: "exit" }
	| { kind: "late_fence" };

const INSTANCE = "f".repeat(32);
const STORE = "0123456789abcdef0123456789abcdef";
const canonical = JSON.stringify({ version: WIRE_VERSION, type: "invocation_error", code: "canonical_store_failure" });
const dispatched = JSON.stringify({ version: WIRE_VERSION, type: "host_unavailable", code: "dispatch_fenced" });
const unrelatedInvocation = JSON.stringify({ version: WIRE_VERSION, type: "invocation_error", code: "invalid_arguments" });
const unrelatedBusy = JSON.stringify({ version: WIRE_VERSION, type: "busy", code: "ordinary_capacity_exhausted" });
const fenceLine = JSON.stringify({ rui_start_error: { code: "store_fenced", message: "the MySQL Store lost ownership or its connection; restart the Host" } }) + "\n";

function hostScript(plans: Step[][], attemptFile: string): string {
	return String.raw`#!/usr/bin/env node
const net = require("node:net");
const fs = require("node:fs");
const path = require("node:path");
const attemptFile = ${JSON.stringify(attemptFile)};
const attempt = fs.existsSync(attemptFile) ? Number(fs.readFileSync(attemptFile, "utf8")) : 0;
fs.writeFileSync(attemptFile, String(attempt + 1));
const steps = (${JSON.stringify(plans)})[attempt] ?? [];
const instance = ${JSON.stringify(INSTANCE)};
const store = ${JSON.stringify(STORE)};
const fenceLine = ${JSON.stringify(fenceLine)};
let bytes = Buffer.alloc(0), server;
const held = [];
const fenceAndExit = () => process.stdout.write(fenceLine, () => process.exit(1));
const respond = (socket, status, body, done) => {
  const reason = status === 200 ? "OK" : status === 500 ? "Internal Server Error" : "Service Unavailable";
  socket.end("HTTP/1.1 " + status + " " + reason + "\r\nContent-Length: " + Buffer.byteLength(body) + "\r\nConnection: close\r\n\r\n" + body, done);
};
process.on("SIGUSR2", () => { for (const [socket, status, body] of held.splice(0)) respond(socket, status, body); });
process.stdin.on("data", chunk => {
  bytes = Buffer.concat([bytes, chunk]);
  if (server || bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE()) return;
  const frame = JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE()).toString());
  bytes.fill(0);
  const socketPath = path.join(frame.interface.dir, "rui.sock");
  fs.rmSync(socketPath, { force: true });
  server = net.createServer(socket => {
    let input = "";
    socket.on("data", chunk => {
      input += chunk.toString();
      const end = input.indexOf("\r\n\r\n");
      if (end < 0) return;
      const length = Number(/content-length: (\d+)/i.exec(input.slice(0, end))[1]);
      if (Buffer.byteLength(input.slice(end + 4)) < length) return;
      if (input.startsWith("POST /v1/host-info ")) {
        return respond(socket, 200, JSON.stringify({ version: ${JSON.stringify(WIRE_VERSION)}, instance, store, active_capacity: "2", intake_capacity: "100", descriptor_limit: "1024", started_at: "1", custody_occupied: "0", paused: false, innodb_doublewrite: "OFF", capabilities: { bash: true, providers: { openai: "key_file" } } }));
      }
      const step = steps.shift() ?? { kind: "reply", status: 200, body: "{}" };
      if (step.kind === "fence") return fenceAndExit();
      if (step.kind === "exit") return process.exit(1);
      if (step.kind === "late_fence") { socket.destroy(); server.close(); return setTimeout(fenceAndExit, 3000); }
      if (step.kind === "hold") return held.push([socket, step.status, step.body]);
      if (step.kind === "reply_then_exit") return respond(socket, step.status, step.body, () => process.exit(1));
      if (step.kind === "reply_then_fence") return respond(socket, step.status, step.body, fenceAndExit);
      return respond(socket, step.status, step.body);
    });
  }).listen(socketPath, () => {
    process.stdout.write("ready instance=" + instance + " store=" + store + "\n");
  });
});
process.stdin.on("end", () => server ? server.close(() => process.exit(0)) : process.exit(0));
`;
}

function settings(directory: string): HostSettings {
	return {
		store: { sqlite: { dir: join(directory, "store") } },
		providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key: "sk-store-failed-test" } },
		execution: { activeCapacity: 2 },
	};
}

async function openScripted(...plans: Step[][]): Promise<{ rui: Rui; close: () => Promise<void> }> {
	const directory = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-store-failed-")));
	const executable = join(directory, "host.cjs");
	writeFileSync(executable, hostScript(plans, join(directory, "attempts")), { mode: 0o700 });
	const rui = await Rui.connect(settings(directory), { binary: executable });
	// A client's child handles are unref'd, so a test awaiting an exit needs its own live handle, as host.test.ts does.
	const alive = setInterval(() => {}, 100);
	return {
		rui,
		close: async () => {
			clearInterval(alive);
			await rui.close();
			rmSync(directory, { recursive: true, force: true });
		},
	};
}

// Readiness probes `/v1/host-info`; the scripted Host answers every other path, so the calls here reach its steps.
const info = (rui: Rui) => rui.call("/v1/scripted", JSON.stringify({ version: WIRE_VERSION, kind: "scripted", store: rui.hostInfo?.store }));

/** The error a call rejects with, or undefined when it resolves. */
async function failureOf(call: Promise<unknown>): Promise<unknown> {
	try {
		await call;
		return undefined;
	} catch (error) {
		return error;
	}
}

test("TS-13 a Store fence latches RuiStoreFailedError over every signal, and nothing else latches it", { timeout: 90_000 }, async (t) => {
	await t.test("a canonical_store_failure reply rejects the pending calls and every later call with one error", async () => {
		const { rui, close } = await openScripted([
			{ kind: "reply", status: 500, body: canonical },
			{ kind: "reply", status: 500, body: canonical },
		]);
		try {
			const [first, second] = await Promise.all([failureOf(info(rui)), failureOf(info(rui))]);
			assert.ok(first instanceof RuiStoreFailedError);
			assert.equal(first.code, "store_failed");
			assert.equal(second, first);
			assert.equal(await failureOf(info(rui)), first);
		} finally {
			await close();
		}
	});

	await t.test("a call queued during restart backoff is rejected by the latch its restarted Host raises", async () => {
		const { rui, close } = await openScripted([{ kind: "exit" }], [{ kind: "fence" }]);
		try {
			const exited = once(rui, "exit");
			const first = failureOf(info(rui));
			await exited;
			// The exit handler schedules the restart before emitting; this call waits in the restart's waiters.
			const queued = failureOf(info(rui));
			const [a, b] = await Promise.all([first, queued]);
			assert.ok(a instanceof RuiStoreFailedError);
			assert.equal(b, a);
			assert.equal(await failureOf(info(rui)), a);
		} finally {
			await close();
		}
	});

	await t.test("a call in flight when another signal latches rejects with the latch, not its own non-fence error", async () => {
		const { rui, close } = await openScripted([
			{ kind: "reply", status: 500, body: canonical },
			{ kind: "hold", status: 500, body: unrelatedInvocation },
		]);
		try {
			// The first request is the canonical reply; the second is held until the latch has been observed.
			const latched = failureOf(info(rui));
			const inFlight = failureOf(info(rui));
			const first = await latched;
			assert.ok(first instanceof RuiStoreFailedError);
			process.kill(rui.pid!, "SIGUSR2");
			assert.equal(await inFlight, first);
		} finally {
			await close();
		}
	});

	await t.test("a store_fenced line written more than 2 s after the connection drops still latches the pending call", async () => {
		const { rui, close } = await openScripted([{ kind: "late_fence" }]);
		try {
			const pending = await failureOf(info(rui));
			assert.ok(pending instanceof RuiStoreFailedError);
			assert.equal(await failureOf(info(rui)), pending);
		} finally {
			await close();
		}
	});

	await t.test("a store_fenced line that a Host writes before exiting latches a call that already succeeded", async () => {
		const { rui, close } = await openScripted([{ kind: "reply_then_fence", status: 200, body: "{}" }]);
		try {
			const exited = once(rui, "exit");
			await info(rui);
			const [event] = await exited;
			assert.equal(event.restarting, false, "a fenced Host is not restarted");
			const later = await failureOf(info(rui));
			assert.ok(later instanceof RuiStoreFailedError);
		} finally {
			await close();
		}
	});

	await t.test("activity watchers parked before the latch reject with it", async () => {
		const { rui, close } = await openScripted([{ kind: "reply", status: 500, body: canonical }]);
		try {
			const watch = rui.activity.watch("s");
			const parked = failureOf(watch.wait(watch.revision, undefined));
			const latch = await failureOf(info(rui));
			assert.ok(latch instanceof RuiStoreFailedError);
			assert.equal(await parked, latch);
		} finally {
			await close();
		}
	});

	await t.test("dispatch_fenced from an ordinary stop is not a signal: the call gets its own error and the Host restarts", async () => {
		const { rui, close } = await openScripted([{ kind: "reply_then_exit", status: 503, body: dispatched }], []);
		try {
			const exited = once(rui, "exit");
			const stopped = await failureOf(info(rui));
			assert.ok(stopped instanceof RuiRequestError);
			assert.equal(stopped.code, "dispatch_fenced");
			const [event] = await exited;
			assert.equal(event.restarting, true);
			assert.ok(Buffer.isBuffer(await info(rui)));
		} finally {
			await close();
		}
	});

	await t.test("an exit without the fence line restarts the Host and the call gets RuiUnavailableError, not the latch", async () => {
		const { rui, close } = await openScripted([{ kind: "exit" }], [{ kind: "exit" }], []);
		try {
			const lost = await failureOf(info(rui));
			assert.ok(lost instanceof RuiUnavailableError);
			assert.ok(!(lost instanceof RuiStoreFailedError));
			assert.ok(Buffer.isBuffer(await info(rui)), "the restarted Host answers later calls");
		} finally {
			await close();
		}
	});

	await t.test("an unrelated 500 or 503 reply does not latch: the next call still reaches the Host", async () => {
		const { rui, close } = await openScripted([
			{ kind: "reply", status: 500, body: unrelatedInvocation },
			{ kind: "reply", status: 503, body: unrelatedBusy },
		]);
		try {
			const first = await failureOf(info(rui));
			assert.ok(first instanceof RuiRequestError);
			assert.equal(first.code, "invalid_arguments");
			const second = await failureOf(info(rui));
			assert.ok(second instanceof RuiRequestError);
			assert.equal(second.code, "ordinary_capacity_exhausted");
			assert.ok(Buffer.isBuffer(await info(rui)));
		} finally {
			await close();
		}
	});
});
