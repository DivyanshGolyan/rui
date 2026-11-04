// Runs against a real Rui. RUI_BINARY names the executable; the build's
// ts-client step passes the one it built.
import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { Rui, RuiStartError, RuiUnavailableError, type ConnectOptions, type ExitEvent } from "../src/index.ts";

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
	const body = `{"version":"8","kind":"host_info","store":${JSON.stringify(rui.hostInfo?.store)}}`;
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
	const created = [...runtimeDirs()].filter((name) => !before.has(name));
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

test("a missing executable is RuiUnavailableError", async () => {
	await assert.rejects(Rui.connect(options(newStore(), { binary: "/nonexistent/rui" })), RuiUnavailableError);
});
