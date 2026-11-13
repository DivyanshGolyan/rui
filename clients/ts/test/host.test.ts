// Runs against a real Rui. RUI_BINARY names the executable; the build's
// ts-client step passes the one it built.
import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { test } from "node:test";

import { Rui, RuiStartError, RuiUnavailableError, type HostSettings, type ClientOptions, type ExitEvent } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";

const binary = process.env.RUI_BINARY;
const skip = binary ? false : "set RUI_BINARY to a built rui";
const key = "sk-ts-client-test";

function settings(store: string, extra: Partial<HostSettings> = {}): HostSettings {
	return {
		store: store.startsWith("mysql://") ? { mysql: { url: store } } : { sqlite: { dir: store } },
		providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key } },
		execution: { activeCapacity: 2 },
		...extra,
	};
}

function connect(store: string, extra: Partial<HostSettings> = {}, options: ClientOptions = {}) {
	return Rui.connect(settings(store, extra), { binary: binary ?? "rui", ...options });
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
	const rui = await connect(store);
	const info = await hostInfo(rui);
	assert.equal(info.active_capacity, "2");
	assert.equal(info.capabilities.providers.openai, "key_file");
	assert.equal(info.store, realpathSync(store));
	assert.equal(rui.hostInfo?.innodb_doublewrite, undefined);
	assert.equal(Object.hasOwn(info, "innodb_doublewrite"), false);
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

test("omitting the SQLite Store discovers its canonical identity beneath an isolated HOME", { skip }, async () => {
	const home = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-default-home-")));
	const oldHome = process.env.HOME;
	const oldStore = process.env.RUI_STORE;
	const unselected = join(home, "unselected-store");
	process.env.HOME = home;
	process.env.RUI_STORE = unselected;
	let rui: Rui | undefined;
	try {
		rui = await Rui.connect({ providers: {} }, { binary: binary ?? "rui" });
		const discovered = rui.hostInfo?.store;
		assert.ok(discovered, "readiness must discover a nonempty Store identity");
		assert.equal(discovered, realpathSync(discovered));
		assert.ok(discovered.startsWith(home + sep), "the Host must choose its Store beneath the isolated HOME");
		assert.notEqual(discovered, unselected, "an unreferenced RUI_STORE must not reach the child");
		assert.ok(!existsSync(unselected));
		const exact = await hostInfo(rui);
		assert.equal(exact.store, discovered, "subsequent requests must name the discovered exact Store");
		assert.equal(exact.instance, rui.hostInfo?.instance);
		if (process.platform === "linux") {
			const environment = readFileSync(`/proc/${rui.pid}/environ`, "utf8").split("\0");
			assert.ok(!environment.some((entry) => entry.startsWith("RUI_STORE=")));
		}
	} finally {
		try {
			await rui?.close();
		} finally {
			if (oldHome === undefined) delete process.env.HOME; else process.env.HOME = oldHome;
			if (oldStore === undefined) delete process.env.RUI_STORE; else process.env.RUI_STORE = oldStore;
			rmSync(home, { recursive: true, force: true });
		}
	}
});

test("an explicit interface never adopts a competing Host for either Store", { skip, timeout: 15_000 }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-interface-")));
	const dir = join(root, "run");
	const first = join(root, "first");
	const holder = await connect(first, { interface: { dir }, execution: { paused: true } });
	try {
		for (const store of [first, join(root, "second")]) {
			let contender: Rui | undefined;
			try {
				await assert.rejects(async () => {
					contender = await connect(store, { interface: { dir }, execution: { paused: false } }, { lockWaitMs: 0 });
				}, (error: unknown) => error instanceof RuiStartError && error.code === (store === first ? "store_locked" : "runtime_dir_unusable"));
			} finally {
				await contender?.close();
			}
			assert.equal((await hostInfo(holder)).paused, true, "the competing Host must remain untouched");
		}
	} finally {
		await holder.close();
		rmSync(root, { recursive: true, force: true });
	}
});

test("a caller's OS-byte interface directory reaches the Host without lossy decoding", { skip }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-byte-interface-")));
	const dir = Buffer.concat([Buffer.from(`${root}/run-`), Buffer.of(255)]);
	mkdirSync(dir, { mode: 0o700 });
	let rui: Rui | undefined;
	try {
		rui = await connect(join(root, "store"), { interface: { dir, lifetime: "detached" } });
		assert.equal(rui.hostInfo?.store, realpathSync(join(root, "store")));
		await rui.close();
		assert.ok(existsSync(dir), "close must not remove the caller's interface directory");
	} finally {
		await rui?.close();
		rmSync(root, { recursive: true, force: true });
	}
});

const invalidInterfaceDirs: unknown[] = [
	{ hex: "00" }, { hex: 123 }, { hex: "gg" }, { hex: "2f", extra: true },
	123, false, "relative/path", "", "absolute\0path",
];

test("invalid interface settings reach their refusing child before any alias effect", { timeout: 10_000 }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-invalid-interface-")));
	const executable = join(root, "refuse.cjs");
	const receipt = join(root, "receipt.json");
	const oldTmp = process.env.TMPDIR;
	writeFileSync(executable, `#!/usr/bin/env node
const fs = require("node:fs"), path = require("node:path");
let bytes = Buffer.alloc(0);
process.stdin.on("data", chunk => {
  bytes = Buffer.concat([bytes, chunk]);
  if (bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE()) return;
  const document = JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE()).toString());
  bytes.fill(0);
  const runtime = fs.readdirSync(process.env.TMPDIR).find(name => name.startsWith("rui-"));
  const runtimeDir = path.join(process.env.TMPDIR, runtime);
  fs.writeFileSync(${JSON.stringify(receipt)}, JSON.stringify({dir:document.interface.dir,runtimeDir,files:fs.readdirSync(runtimeDir)}));
  process.stdout.write(JSON.stringify({rui_start_error:{code:"settings_invalid",message:"interface.dir: invalid settings"}})+"\\n",()=>process.exit(1));
});
`, { mode: 0o700 });
	process.env.TMPDIR = root;
	try {
		for (const dir of invalidInterfaceDirs) {
			await assert.rejects(Rui.connect({ providers: {}, interface: { dir } } as HostSettings, { binary: executable }), (error: unknown) => {
				assert.ok(error instanceof RuiStartError, "the child settings refusal must win over Node path errors");
				assert.equal(error.code, "settings_invalid");
				assert.match(error.message, /interface\.dir/);
				return true;
			});
			const observed = JSON.parse(readFileSync(receipt, "utf8"));
			assert.deepEqual(observed.dir, dir, "the child must receive the malformed directory unchanged");
			assert.deepEqual(observed.files, [], "no alias effect may run before child readiness");
			assert.equal(existsSync(observed.runtimeDir), false, "failed connect must clean its private runtime directory");
		}
	} finally {
		if (oldTmp === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = oldTmp;
		rmSync(root, { recursive: true, force: true });
	}
});

test("a real Host owns malformed interface settings refusals", { skip, timeout: 15_000 }, async () => {
	for (const dir of invalidInterfaceDirs) {
		await assert.rejects(Rui.connect({ providers: {}, interface: { dir } } as HostSettings, { binary: binary ?? "rui" }), (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "settings_invalid");
			assert.match(error.message, /interface\.dir/);
			return true;
		});
	}
});

test("an alias failure after readiness kills and reaps its own child before cleanup", { timeout: 10_000 }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-alias-failure-")));
	const executable = join(root, "ready.cjs");
	const receipt = join(root, "receipt.json");
	const oldTmp = process.env.TMPDIR;
	writeFileSync(executable, `#!/usr/bin/env node
const fs = require("node:fs");
let bytes = Buffer.alloc(0);
process.stdin.on("data", chunk => {
  bytes = Buffer.concat([bytes, chunk]);
  if (bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE()) return;
  const document = JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE()).toString());
  bytes.fill(0);
  fs.writeFileSync(require("node:path").join(document.interface.dir,"interface"), "occupied");
  fs.writeFileSync(${JSON.stringify(receipt)}, JSON.stringify({pid:process.pid,runtimeDir:document.interface.dir}));
  process.stdout.write("ready instance="+"a".repeat(32)+" store=fixture\\n");
});
`, { mode: 0o700 });
	process.env.TMPDIR = root;
	try {
		await assert.rejects(Rui.connect({ providers: {} }, { binary: executable }), (error: unknown) => (error as NodeJS.ErrnoException).code === "EEXIST");
		const observed = JSON.parse(readFileSync(receipt, "utf8"));
		assert.throws(() => process.kill(observed.pid, 0), (error: unknown) => (error as NodeJS.ErrnoException).code === "ESRCH", "the owned child must be reaped before connect rejects");
		assert.equal(existsSync(observed.runtimeDir), false);
	} finally {
		if (oldTmp === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = oldTmp;
		rmSync(root, { recursive: true, force: true });
	}
});

test("without its child's readiness receipt connect never probes an existing socket", { timeout: 10_000 }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-existing-interface-")));
	const executable = join(root, "refuse.cjs");
	writeFileSync(executable, `#!/usr/bin/env node\nprocess.stdin.resume();\nprocess.stdout.write(JSON.stringify({rui_start_error:{code:"runtime_dir_unusable",message:"interface directory is in use"}})+"\\n",()=>process.exit(1));\n`, { mode: 0o700 });
	let probes = 0;
	const existing = createServer((_request, reply) => {
		probes++;
		reply.end(JSON.stringify({ instance: "1".repeat(32), store: "/unrelated-existing-store" }));
	});
	existing.listen(join(root, "rui.sock"));
	let adopted: Rui | undefined;
	try {
		await once(existing, "listening");
		await assert.rejects(async () => {
			adopted = await connect(newStore(), { interface: { dir: root } }, { binary: executable });
		}, (error: unknown) => error instanceof RuiStartError && error.code === "runtime_dir_unusable");
		assert.equal(probes, 0);
	} finally {
		await adopted?.close();
		existing.closeAllConnections();
		await new Promise<void>((resolve, reject) => existing.close((error) => error ? reject(error) : resolve()));
		rmSync(root, { recursive: true, force: true });
	}
});

test("a child's receipt must match the socket's instance before adoption", { timeout: 10_000 }, async () => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-instance-interface-")));
	const executable = join(root, "receipt.cjs");
	const instance = "a".repeat(32);
	writeFileSync(executable, `#!/usr/bin/env node\nprocess.stdin.resume();\nprocess.stdout.write("ready instance=${instance} store=child\\n");\n`, { mode: 0o700 });
	const seen: (string | string[] | undefined)[] = [];
	const existing = createServer((request, reply) => {
		seen.push(request.headers["x-rui-host-instance"]);
		reply.end(JSON.stringify({ instance: "b".repeat(32), store: "/existing-store" }));
	});
	existing.listen(join(root, "rui.sock"));
	let adopted: Rui | undefined;
	try {
		await once(existing, "listening");
		await assert.rejects(async () => {
			adopted = await connect(newStore(), { interface: { dir: root } }, { binary: executable });
		}, (error: unknown) => error instanceof RuiUnavailableError && /readiness instance/.test(error.message));
		assert.deepEqual(seen, [instance]);
	} finally {
		await adopted?.close();
		existing.closeAllConnections();
		await new Promise<void>((resolve, reject) => existing.close((error) => error ? reject(error) : resolve()));
		rmSync(root, { recursive: true, force: true });
	}
});

test("an explicitly named OpenAI environment source reaches the child, not the document", { skip }, async () => {
	const name = "RUI_TS_OPENAI_SOURCE";
	const previous = process.env[name];
	process.env[name] = key;
	let rui: Rui | undefined;
	try {
		rui = await connect(newStore(), { providers: { openai: { key: { env: name } } } });
		assert.equal(rui.hostInfo?.capabilities.providers.openai, "key_file");
		if (process.platform === "linux") {
			assert.ok(readFileSync(`/proc/${rui.pid}/environ`, "utf8").split("\0").includes(`${name}=${key}`));
			assert.ok(!readFileSync(`/proc/${rui.pid}/cmdline`, "utf8").includes(key));
		}
	} finally {
		await rui?.close();
		if (previous === undefined) delete process.env[name]; else process.env[name] = previous;
	}
});

test("closing Rui rejects a parked follower and releases its watch without aborting", { skip, timeout: 10_000 }, async (t) => {
	const rui = await connect(newStore());
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
		delta: "full", since: null, items: [], more: false, end: "0", queued: { count: "0" }, work: { state: { kind: "idle" } },
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
	const rui = await connect(newStore(), { execution: { paused: true } });
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
	const rui = await connect(newStore());
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
	const rui = await connect(newStore());
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
	const holder = await connect(store);
	try {
		const started = Date.now();
		await assert.rejects(connect(store, {}, { lockWaitMs: 1_000 }), (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "store_locked");
			return true;
		});
		assert.ok(Date.now() - started >= 1_000);
		const waiting = connect(store, {}, { lockWaitMs: 30_000 });
		await holder.close();
		const second = await waiting;
		await second.close();
	} finally {
		await holder.close();
	}
});

test("a refused settings document is a RuiStartError", { skip }, async () => {
	const refused = connect(newStore(), { providers: { openai: { endpoint: "http://plain.example", key } } });
	await assert.rejects(refused, (error: unknown) => {
		assert.ok(error instanceof RuiStartError);
		assert.equal(error.code, "settings_invalid");
		assert.match(error.message, /providers\.openai\.endpoint/);
		return true;
	});
});

test("invalid provider CA paths are refused with the settings document", { skip }, async () => {
	for (const caFile of ["/tmp/ca.pem\0ignored"]) {
		await assert.rejects(connect(newStore(), {
			providers: { openai: { endpoint: "https://example.com/v1", key } }, network: { caFile },
		}), (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "settings_invalid");
			assert.match(error.message, /network\.caFile/);
			return true;
		});
	}
});

test("an invalid MCP server is a RuiStartError", { skip }, async () => {
	const token = "mcp-secret-test";
	const tools = { mcp: { drift: { url: "https://example.com/mcp", bearerToken: token, callTimeoutMs: 1000 } } };
	await assert.rejects(connect(newStore(), { tools }), (error: unknown) => {
		assert.ok(error instanceof RuiStartError);
		assert.equal(error.code, "settings_invalid");
		assert.match(error.message, /tools\.mcp/);
		assert.ok(!error.message.includes(token));
		return true;
	});
});

test("a missing executable is RuiUnavailableError", async () => {
	await assert.rejects(connect(newStore(), {}, { binary: "/nonexistent/rui" }), RuiUnavailableError);
});

function mysqlHost(refusals: (RuiStartError["code"] | null)[] = []) {
	const directory = mkdtempSync(join(tmpdir(), "rui-ts-mysql-"));
	const executable = join(directory, "host.cjs");
	writeFileSync(executable, String.raw`#!/usr/bin/env node
const net = require("node:net");
const fs = require("node:fs");
const counter = ${JSON.stringify(join(directory, "attempts"))};
const attempt = fs.existsSync(counter) ? Number(fs.readFileSync(counter, "utf8")) : 0;
fs.writeFileSync(counter, String(attempt + 1));
const refusal = ${JSON.stringify(refusals)}[attempt];
let bytes = Buffer.alloc(0), server;
const id = "0123456789abcdef0123456789abcdef";
process.stdin.on("data", chunk => {
  bytes = Buffer.concat([bytes, chunk]);
  if (server || bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE()) return;
  const frame = JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE()).toString());
  bytes.fill(0);
  if (!frame.store.mysql.url.value.startsWith("mysql://") || Object.values(process.env).includes(frame.store.mysql.url.value) || process.argv.includes(frame.store.mysql.url.value)) process.exit(2);
  if (process.argv.slice(2).join(" ") !== "host serve --settings -") process.exit(4);
  if (refusal) {
    process.stdout.write(JSON.stringify({rui_start_error:{code:refusal,message:"could not connect to the MySQL server"}}) + "\n", () => process.exit(1));
    return;
  }
  fs.rmSync(require("node:path").join(frame.interface.dir, "rui.sock"), {force:true});
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
      const body = JSON.stringify({version:${JSON.stringify(WIRE_VERSION)},type:"host_info",store:id,instance:String(attempt).padStart(32, "0"),active_capacity:"2",intake_capacity:"100",descriptor_limit:"1024",started_at:"1792918800",custody_occupied:"0",paused:false,innodb_doublewrite:"OFF",capabilities:{bash:true,providers:{codex:"unserved",openai:"key_file"}}});
      socket.end("HTTP/1.1 200 OK\r\nContent-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body);
    });
  }).listen(require("node:path").join(frame.interface.dir, "rui.sock"), () => {
    process.stdout.write("ready instance=" + String(attempt).padStart(32, "0") + " store=" + id + "\n");
  });
});
process.stdin.on("end", () => server ? server.close(() => process.exit(0)) : process.exit(0));
`, { mode: 0o700 });
	return {
		executable,
		attempts: () => Number(readFileSync(join(directory, "attempts"), "utf8")),
		close: () => rmSync(directory, { recursive: true, force: true }),
	};
}

test("MySQL readiness discovers an opaque id without sending the URL on requests", async () => {
	const fixture = mysqlHost();
	let rui: Rui | undefined;
	try {
		rui = await connect("mysql://user:private@localhost/db", {}, { binary: fixture.executable });
		const id = "0123456789abcdef0123456789abcdef";
		assert.equal(rui.hostInfo?.store, id);
		// No property-presence/union narrowing is needed on the shared shape.
		const doublewrite: string | undefined = rui.hostInfo?.innodb_doublewrite;
		assert.equal(doublewrite, "OFF");
		await rui.exchange("/v1/host-info", store => {
			assert.equal(store, id);
			return JSON.stringify({ version: WIRE_VERSION, kind: "host_info", store });
		});
	} finally {
		await rui?.close();
		fixture.close();
	}
});

test("automatic restart retries an unreachable MySQL server and recovers", { timeout: 10_000 }, async () => {
	// An idle client unreferences its child and restart timer; keep the test alive while awaiting exit.
	const alive = setInterval(() => {}, 100);
	const fixture = mysqlHost([null, "mysql_unreachable", null]);
	let rui: Rui | undefined;
	try {
		rui = await connect("mysql://user:private@localhost/db", {}, { binary: fixture.executable });
		const client = rui;
		const first = client.hostInfo!.instance;
		const info = () => client.exchange("/v1/host-info", store => JSON.stringify({ version: WIRE_VERSION, kind: "host_info", store }));
		const exited = once(client, "exit");
		process.kill(client.pid!, "SIGKILL");
		await exited;
		const refused = once(client, "exit");
		await assert.rejects(info(), (error: unknown) => {
			assert.ok(error instanceof RuiUnavailableError);
			assert.ok(error.cause instanceof RuiStartError);
			assert.equal(error.cause.code, "mysql_unreachable");
			return true;
		});
		assert.deepEqual((await refused)[0], { code: 1, signal: null, restarting: true });
		const recovered = JSON.parse((await info()).toString("utf8"));
		assert.notEqual(recovered.instance, first);
		assert.equal(fixture.attempts(), 3);
	} finally {
		clearInterval(alive);
		await rui?.close();
		fixture.close();
	}
});

test("initial connect rejects mysql_unreachable without retrying", { timeout: 10_000 }, async () => {
	const fixture = mysqlHost(["mysql_unreachable", null]);
	let rui: Rui | undefined;
	try {
		await assert.rejects(async () => {
			rui = await connect("mysql://user:private@localhost/db", {}, { binary: fixture.executable });
		}, (error: unknown) => {
			assert.ok(error instanceof RuiStartError);
			assert.equal(error.code, "mysql_unreachable");
			return true;
		});
		assert.equal(fixture.attempts(), 1);
	} finally {
		await rui?.close();
		fixture.close();
	}
});


test("restart-owned document bytes are erased on close and fatal restart", { timeout: 10_000 }, async (t) => {
	const buffers: Buffer[] = [];
	const allocate = Buffer.alloc;
	t.mock.method(Buffer, "alloc", (...args: Parameters<typeof Buffer.alloc>) => {
		const bytes = allocate(...args);
		buffers.push(bytes);
		return bytes;
	});
	for (const fatal of [false, true]) {
		const fixture = mysqlHost(fatal ? [null, "mysql_login"] : []);
		const alive = setInterval(() => {}, 100);
		let rui: Rui | undefined;
		try {
			rui = await connect("mysql://user:private-document-marker@localhost/db", {}, { binary: fixture.executable });
			const retained = buffers.filter((bytes) => bytes.includes("private-document-marker"));
			assert.equal(retained.length, 1, "only one mutable restart document should retain literal secrets");
			if (fatal) {
				const exited = once(rui, "exit");
				process.kill(rui.pid!, "SIGKILL");
				await exited;
				await assert.rejects(hostInfo(rui), (error: unknown) => error instanceof RuiUnavailableError && error.cause instanceof RuiStartError && error.cause.code === "mysql_login");
			} else await rui.close();
			assert.ok(retained.every((bytes) => bytes.every((byte) => byte === 0)), "terminal transition must erase the retained document");
		} finally {
			clearInterval(alive);
			await rui?.close();
			fixture.close();
		}
	}
});
