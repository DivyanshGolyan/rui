// Runs against a real Rui. RUI_BINARY names the executable; the build's
// ts-client step passes the one it built.
import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiStartError, RuiUnavailableError, type ConnectOptions, type ExitEvent } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";

const binary = process.env.RUI_BINARY;
const skip = binary ? false : "set RUI_BINARY to a built rui";
const key = "sk-ts-client-test";

function options(store: string, extra: Partial<ConnectOptions> = {}): ConnectOptions {
	return {
		database: store,
		provider: { baseUrl: "https://api.openai.com/v1", key },
		activeCapacity: 2,
		binary: binary ?? "rui",
		...extra,
	};
}

function newStore(): string {
	return join(realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-"))), "store");
}

// Test files run one at a time (--test-concurrency=1): another file's Hosts would show up here.
function runtimeDirs(): Set<string> {
	return new Set(readdirSync(tmpdir()).filter((name) => name.startsWith("rui-")));
}

async function hostInfo(rui: Rui) {
	const body = JSON.stringify({ version: WIRE_VERSION, kind: "host_info", store: rui.hostInfo?.store });
	return JSON.parse((await rui.call("/v1/host-info", body)).toString("utf8"));
}

test("connect starts a ready Host and close stops it", { skip }, async () => {
	const store = newStore();
	const before = runtimeDirs();
	const rui = await Rui.connect(options(store));
	const info = await hostInfo(rui);
	assert.equal(info.active_capacity, "2");
	assert.equal(info.capabilities.providers.openai, "key_file");
	assert.equal(info.store, realpathSync(store));
	if (process.platform === "linux") {
		const pid = rui.pid;
		const environment = readFileSync(`/proc/${pid}/environ`, "utf8").split("\0").filter(Boolean);
		assert.deepEqual(environment.map((entry) => entry.split("=")[0]).sort(), ["HOME", "PATH", "TMPDIR"].filter((name) => process.env[name] !== undefined).sort());
		for (const file of ["environ", "cmdline"]) assert.ok(!readFileSync(`/proc/${pid}/${file}`, "utf8").includes(key), file);
	}
	const created = [...runtimeDirs()].filter((name) => !before.has(name) && !name.startsWith("rui-ts-"));
	assert.equal(created.length, 1, String(created));

	const exits: ExitEvent[] = [];
	rui.on("exit", (exit) => exits.push(exit));
	const started = Date.now();
	await rui.close();
	assert.ok(Date.now() - started < 10_000);
	assert.deepEqual(exits, [{ code: 0, signal: null, restarting: false }]);
	assert.ok(!existsSync(join(tmpdir(), created[0]!)), "runtimeDir left behind");
	await assert.rejects(hostInfo(rui), RuiUnavailableError);
});

test("closing Rui rejects a parked follower and releases its watch without aborting", { skip, timeout: 10_000 }, async (t) => {
	const rui = await Rui.connect(options(newStore()));
	const controller = new AbortController();
	let follower: ReturnType<typeof rui.activity.watch> | undefined;
	let park = () => {};
	const parked = new Promise<void>((resolve) => { park = resolve; });
	const watch = rui.activity.watch.bind(rui.activity);
	t.mock.method(rui.activity, "watch", (session: string) => {
		follower = watch(session);
		const wait = follower.wait.bind(follower);
		t.mock.method(follower, "wait", (...args: Parameters<typeof wait>) => {
			const pending = wait(...args);
			park();
			return pending;
		});
		return follower;
	});
	// Only the idle page is synthetic; close still exercises the real Rui lifecycle.
	t.mock.method(rui, "exchange", async () => Buffer.from(JSON.stringify({
		items: [], more: false, end: "0", queued: { count: "0" }, work: { state: { kind: "idle" } },
	})));
	const feed = rui.getSession("s").listActivity({ follow: true, signal: controller.signal });
	let failure: unknown;
	const pending = feed.next().catch((error: unknown) => { failure = error; });
	try {
		await parked;
		await rui.close();
		assert.equal(controller.signal.aborted, false);
		assert.ok(failure instanceof RuiUnavailableError, "close must reject the parked read before returning");
		assert.equal(failure.message, "the Rui client is closed");
		await pending;
		assert.ok(follower);
		rui.activity.notify("s");
		assert.equal(follower.revision, 0, "the follower's subscription must be released");
	} finally {
		controller.abort();
		await pending;
		await feed.return(undefined);
		await rui.close();
	}
});

test("a Host opened paused holds Turns until resume, and a restarted one opens paused again", { skip }, async () => {
	const rui = await Rui.connect(options(newStore(), { paused: true }));
	try {
		assert.equal((await hostInfo(rui)).paused, true);
		await rui.resume();
		assert.equal((await hostInfo(rui)).paused, false);
		const exited = once(rui, "exit");
		process.kill(rui.pid!, "SIGKILL");
		const retried = hostInfo(rui);
		await exited;
		assert.equal((await retried).paused, true);
	} finally {
		await rui.close();
	}
});

test("a crashed Host restarts and the call in flight is sent again", { skip }, async () => {
	const rui = await Rui.connect(options(newStore()));
	try {
		const first = rui.hostInfo!.instance;
		const exited = once(rui, "exit");
		process.kill(rui.pid!, "SIGKILL");
		const retried = hostInfo(rui);
		assert.deepEqual((await exited)[0], { code: null, signal: "SIGKILL", restarting: true });
		const info = await retried;
		assert.notEqual(info.instance, first);
		assert.equal(rui.hostInfo!.instance, info.instance);
	} finally {
		await rui.close();
	}
});

test("an exit listener that closes the client stops the restart", { skip }, async () => {
	const before = runtimeDirs();
	const rui = await Rui.connect(options(newStore()));
	// The client keeps nothing alive by itself (the child is unreferenced), so the test does.
	const alive = setInterval(() => {}, 100);
	try {
		const closed = new Promise<void>((done) => rui.on("exit", () => void rui.close().then(done)));
		process.kill(rui.pid!, "SIGKILL");
		await closed;
		// The first restart would have come 0.5 s after the exit.
		await new Promise((done) => setTimeout(done, 1_500));
		assert.equal(rui.pid, undefined);
		assert.deepEqual([...runtimeDirs()].filter((name) => !before.has(name) && !name.startsWith("rui-ts-")), []);
		await assert.rejects(hostInfo(rui), RuiUnavailableError);
	} finally {
		clearInterval(alive);
	}
});

test("connect waits for the Store lock, then gives up with store_locked", { skip }, async () => {
	const store = newStore();
	const holder = await Rui.connect(options(store));
	try {
		const started = Date.now();
		await assert.rejects(Rui.connect(options(store, { lockWaitMs: 1_000 })), (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "store_locked");
			return true;
		});
		assert.ok(Date.now() - started >= 1_000);
		const waiting = Rui.connect(options(store, { lockWaitMs: 30_000 }));
		await holder.close();
		const second = await waiting;
		await second.close();
	} finally {
		await holder.close();
	}
});

test("a refused frame is a RuiStartError", { skip }, async () => {
	const refused = Rui.connect(options(newStore(), { provider: { baseUrl: "http://plain.example", key } }));
	await assert.rejects(refused, (error: unknown) => {
		assert.ok(error instanceof RuiStartError);
		assert.equal(error.code, "launch_frame_invalid");
		assert.match(error.message, /provider\.baseUrl/);
		return true;
	});
});

test("invalid provider CA paths are refused with the launch frame", { skip }, async () => {
	for (const caFile of ["", "/tmp/ca.pem\0ignored"]) {
		await assert.rejects(Rui.connect(options(newStore(), {
			provider: { baseUrl: "https://example.com/v1", key, caFile },
		})), (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "launch_frame_invalid");
			assert.match(error.message, /provider\.caFile/);
			return true;
		});
	}
});

test("an invalid MCP server is a RuiStartError", { skip }, async () => {
	const token = "mcp-secret-test";
	const tools = [{ name: "drift", url: "https://example.com/mcp", bearerToken: token, callTimeoutMs: 1000 }];
	await assert.rejects(Rui.connect(options(newStore(), { tools })), (error: unknown) => {
		assert.ok(error instanceof RuiStartError);
		assert.equal(error.code, "launch_frame_invalid");
		assert.match(error.message, /mcpServers/);
		assert.ok(!error.message.includes(token));
		return true;
	});
});

test("a missing executable is RuiUnavailableError", async () => {
	await assert.rejects(Rui.connect(options(newStore(), { binary: "/nonexistent/rui" })), RuiUnavailableError);
});

test("MySQL readiness discovers an opaque id without sending the URL on requests", async () => {
	const directory = mkdtempSync(join(tmpdir(), "rui-ts-mysql-"));
	const executable = join(directory, "host.cjs");
	writeFileSync(executable, String.raw`#!/usr/bin/env node
const net = require("node:net");
let bytes = Buffer.alloc(0), server;
const id = "0123456789abcdef0123456789abcdef";
process.stdin.on("data", chunk => {
  bytes = Buffer.concat([bytes, chunk]);
  if (server || bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE()) return;
  const frame = JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE()).toString());
  bytes.fill(0);
  if (!frame.store.startsWith("mysql://") || Object.values(process.env).includes(frame.store) || process.argv.includes(frame.store)) process.exit(2);
  server = net.createServer(socket => {
    let input = "";
    socket.on("data", chunk => {
      input += chunk.toString();
      const end = input.indexOf("\r\n\r\n");
      if (end < 0) return;
      const length = Number(/content-length: (\d+)/i.exec(input.slice(0, end))[1]);
      if (Buffer.byteLength(input.slice(end + 4)) < length) return;
      const request = JSON.parse(input.slice(end + 4));
      if (request.store !== "" && request.store !== id) process.exit(3);
      const body = JSON.stringify({version:${JSON.stringify(WIRE_VERSION)},type:"host_info",store:id,instance:"a".repeat(32),active_capacity:"2",intake_capacity:"100",descriptor_limit:"1024",started_at:"1792918800",custody_occupied:"0",paused:false,innodb_doublewrite:"OFF",capabilities:{bash:true,providers:{codex:"unserved",openai:"key_file"}}});
      socket.end("HTTP/1.1 200 OK\r\nContent-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body);
    });
  }).listen(require("node:path").join(frame.runtimeDir, "rui.sock"));
});
process.stdin.on("end", () => server ? server.close(() => process.exit(0)) : process.exit(0));
`, { mode: 0o700 });
	let rui: Rui | undefined;
	try {
		rui = await Rui.connect(options("mysql://user:private@localhost/db", { binary: executable }));
		const id = "0123456789abcdef0123456789abcdef";
		assert.equal(rui.hostInfo?.store, id);
		assert.ok(rui.hostInfo && "innodb_doublewrite" in rui.hostInfo);
		assert.equal(rui.hostInfo.innodb_doublewrite, "OFF");
		await rui.exchange("/v1/host-info", store => {
			assert.equal(store, id);
			return JSON.stringify({ version: WIRE_VERSION, kind: "host_info", store });
		});
	} finally {
		await rui?.close();
		rmSync(directory, { recursive: true, force: true });
	}
});
