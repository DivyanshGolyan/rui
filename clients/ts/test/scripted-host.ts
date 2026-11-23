import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Rui, RuiStoreFailedError, type HostSettings } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";

// A scripted Host. Each spawn is one attempt and takes the next plan, so a restart meets its own steps. A step answers
// one non-readiness request: a reply, a reply that then ends the Host, a fence line (with or without a later reply), a
// plain exit, a held request released by SIGUSR2, or a fence line written long after the connection drops.
export type Step =
	| { kind: "reply"; status: number; body: string }
	| { kind: "reply_then_exit"; status: number; body: string }
	| { kind: "reply_then_fence"; status: number; body: string }
	| { kind: "hold"; status: number; body: string }
	| { kind: "fence" }
	| { kind: "exit" }
	| { kind: "late_fence" };

export const INSTANCE = "f".repeat(32);
export const STORE = "0123456789abcdef0123456789abcdef";
export const canonical = JSON.stringify({ version: WIRE_VERSION, type: "invocation_error", code: "canonical_store_failure" });
export const dispatched = JSON.stringify({ version: WIRE_VERSION, type: "host_unavailable", code: "dispatch_fenced" });
// A feed page with no rows: a watch reads it, then waits for a nudge. `work` is what the page reader requires.
export const emptyPage = JSON.stringify({ version: WIRE_VERSION, type: "activity_page", delta: "full", since: "t0", items: [], more: false, end: "0", queued: { count: "0" }, work: { attention: null, group: "done", actions: { stop: false, interrupt: null, decide: null }, state: { kind: "idle", since: "1" } } });
export const unrelatedInvocation = JSON.stringify({ version: WIRE_VERSION, type: "invocation_error", code: "invalid_arguments" });
export const unrelatedBusy = JSON.stringify({ version: WIRE_VERSION, type: "busy", code: "ordinary_capacity_exhausted" });
export const fenceLine = JSON.stringify({ rui_start_error: { code: "store_fenced", message: "the MySQL Store lost ownership or its connection; restart the Host" } }) + "\n";

function hostScript(plans: Step[][], attemptFile: string, lineFrames: object[][] = []): string {
	return String.raw`#!/usr/bin/env node
const net = require("node:net");
const fs = require("node:fs");
const path = require("node:path");
const attemptFile = ${JSON.stringify(attemptFile)};
const attempt = fs.existsSync(attemptFile) ? Number(fs.readFileSync(attemptFile, "utf8")) : 0;
fs.writeFileSync(attemptFile, String(attempt + 1));
const steps = (${JSON.stringify(plans)})[attempt] ?? [];
const frames = (${JSON.stringify(lineFrames)})[attempt] ?? [];
const queue = frames.map((value) => value);
let lineSocket;
const pump = (socket) => {
  while (queue.length > 0) {
    const value = queue[0];
    if (value.wait) return;
    queue.shift();
    if (value.drop) return socket.end();
    if (value.exit) return setTimeout(() => process.exit(1), 20);
    if (value.silent || value.refuse) continue;
    socket.write(frameOf(value));
  }
};
process.on("SIGUSR1", () => {
  if (!lineSocket || lineSocket.destroyed || queue[0]?.wait !== true) return;
  queue.shift();
  pump(lineSocket);
});
const frameOf = (value) => { const json = Buffer.from(JSON.stringify(value)); const out = Buffer.alloc(4 + json.length); out.writeUInt32BE(json.length, 0); json.copy(out, 4); return out; };
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
    let upgraded = false;
    socket.on("data", chunk => {
      if (upgraded) return;
      input += chunk.toString();
      const end = input.indexOf("\r\n\r\n");
      if (end < 0) return;
      if (input.startsWith("GET /v1/line ")) {
        // The line: hello, then the attempt's line queue, then a changed nudge for each watched Session after each watch frame,
        // as the Host sends. A marker in the queue: wait holds the queue until SIGUSR1; drop ends the line; exit ends the Host;
        // refuse answers the upgrade with a reply. Frames the client sends are read in full, so each watch set is answered.
        const refusal = queue[0] && queue[0].refuse;
        if (refusal) {
          queue.shift();
          return respond(socket, refusal.status, refusal.body);
        }
        upgraded = true;
        socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: rui-line/1\r\nConnection: Upgrade\r\n\r\n");
        socket.write(frameOf({ type: "hello", line: 1, instance }));
        // A frame with silent set is a Host that closes its line after hello, without answering a watch.
        if (frames.some((value) => value.silent)) return socket.end();
        lineSocket = socket;
        socket.on("close", () => { if (lineSocket === socket) lineSocket = undefined; });
        pump(socket);
        let pending = Buffer.alloc(0);
        socket.on("data", bytes => {
          pending = Buffer.concat([pending, bytes]);
          while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32BE(0)) {
            const length = pending.readUInt32BE(0);
            const value = JSON.parse(pending.subarray(4, 4 + length).toString());
            pending = pending.subarray(4 + length);
            if (value.type === "watch") for (const session of value.sessions) socket.write(frameOf({ type: "changed", session }));
          }
        });
        return;
      }
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
process.stdin.on("end", () => { if (!server) return process.exit(0); server.close(() => process.exit(0)); server.closeAllConnections(); });
`;
}

function settings(directory: string): HostSettings {
	return {
		store: { sqlite: { dir: join(directory, "store") } },
		providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key: "sk-store-failed-test" } },
		execution: { activeCapacity: 2 },
	};
}

export async function openScripted(...plans: Step[][]): Promise<{ rui: Rui; close: () => Promise<void> }> {
	return openScriptedLine([], ...plans);
}

/** As `openScripted`, and each attempt's line sends its `lineFrames` entry after `hello`. */
export async function openScriptedLine(lineFrames: object[][], ...plans: Step[][]): Promise<{ rui: Rui; close: () => Promise<void> }> {
	const directory = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-store-failed-")));
	const executable = join(directory, "host.cjs");
	writeFileSync(executable, hostScript(plans, join(directory, "attempts"), lineFrames), { mode: 0o700 });
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
export const info = (rui: Rui) => rui.call("/v1/scripted", JSON.stringify({ version: WIRE_VERSION, kind: "scripted", store: rui.hostInfo?.store }));

/** The error a call rejects with, or undefined when it resolves. */
export async function failureOf(call: Promise<unknown>): Promise<unknown> {
	try {
		await call;
		return undefined;
	} catch (error) {
		return error;
	}
}
