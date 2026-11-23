import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiRequestError, RuiStoreFailedError, type HostSettings } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";

// A scripted Host: it serves readiness and then answers each non-readiness request with the next step.
type Step =
	| { kind: "reply"; status: number; body: string }
	| { kind: "reply_then_fence"; status: number; body: string }
	| { kind: "fence" };

const INSTANCE = "f".repeat(32);
const STORE = "0123456789abcdef0123456789abcdef";
const canonical = JSON.stringify({ version: WIRE_VERSION, type: "invocation_error", code: "canonical_store_failure" });
const dispatched = JSON.stringify({ version: WIRE_VERSION, type: "host_unavailable", code: "dispatch_fenced" });
const unrelatedInvocation = JSON.stringify({ version: WIRE_VERSION, type: "invocation_error", code: "invalid_arguments" });
const unrelatedBusy = JSON.stringify({ version: WIRE_VERSION, type: "busy", code: "ordinary_capacity_exhausted" });
const fenceLine = JSON.stringify({ rui_start_error: { code: "store_fenced", message: "the MySQL Store lost ownership or its connection; restart the Host" } }) + "\n";

function hostScript(steps: Step[]): string {
	return String.raw`#!/usr/bin/env node
const net = require("node:net");
const fs = require("node:fs");
const path = require("node:path");
const steps = ${JSON.stringify(steps)};
const instance = ${JSON.stringify(INSTANCE)};
const store = ${JSON.stringify(STORE)};
const fenceLine = ${JSON.stringify(fenceLine)};
let bytes = Buffer.alloc(0), server;
const fenceAndExit = () => process.stdout.write(fenceLine, () => process.exit(1));
const respond = (socket, status, body, done) => {
  const reason = status === 200 ? "OK" : status === 500 ? "Internal Server Error" : "Service Unavailable";
  socket.end("HTTP/1.1 " + status + " " + reason + "\r\nContent-Length: " + Buffer.byteLength(body) + "\r\nConnection: close\r\n\r\n" + body, done);
};
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

async function openScripted(steps: Step[]): Promise<{ rui: Rui; close: () => Promise<void> }> {
	const directory = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-store-failed-")));
	const executable = join(directory, "host.cjs");
	writeFileSync(executable, hostScript(steps), { mode: 0o700 });
	const rui = await Rui.connect(settings(directory), { binary: executable });
	return {
		rui,
		close: async () => {
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

test("TS-13 a Store fence latches RuiStoreFailedError over every signal, and nothing else latches it", { timeout: 60_000 }, async (t) => {
	await t.test("a canonical_store_failure reply rejects the pending calls and every later call with one error", async () => {
		const { rui, close } = await openScripted([
			{ kind: "reply", status: 500, body: canonical },
			{ kind: "reply", status: 500, body: canonical },
		]);
		try {
			const [first, second] = await Promise.all([failureOf(info(rui)), failureOf(info(rui))]);
			assert.ok(first instanceof RuiStoreFailedError);
			assert.equal(second, first);
			const later = await failureOf(info(rui));
			assert.equal(later, first);
		} finally {
			await close();
		}
	});

	await t.test("a dispatch_fenced reply rejects the pending calls and every later call with one error", async () => {
		const { rui, close } = await openScripted([
			{ kind: "reply", status: 503, body: dispatched },
			{ kind: "reply", status: 503, body: dispatched },
		]);
		try {
			const [first, second] = await Promise.all([failureOf(info(rui)), failureOf(info(rui))]);
			assert.ok(first instanceof RuiStoreFailedError);
			assert.equal(second, first);
			assert.equal(await failureOf(info(rui)), first);
		} finally {
			await close();
		}
	});

	await t.test("a Host that exits after its store_fenced line rejects the pending call with the latch, not RuiUnavailableError", async () => {
		const { rui, close } = await openScripted([{ kind: "fence" }]);
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
