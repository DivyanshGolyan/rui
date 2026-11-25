import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError, type Rui } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import { nextKeys } from "./scripted-line.ts";
import { emptyPage, failureOf, info, openScriptedLine } from "./scripted-host.ts";

// TS-14 at the client: how the line's frames become feed reads. The scripted Host's line queue holds the frames of each
// attempt; `wait` holds the queue until the test sends SIGUSR1, so each frame arrives when the test releases it.

const SESSION = "k7m2qx";

/** A feed page holding `rows` (position, key), in order, with the cursor at the last position. */
function pageOf(rows: [number, string][]): string {
	const last = rows.at(-1)?.[0] ?? 0;
	return JSON.stringify({
		version: WIRE_VERSION, type: "activity_page", delta: "full", since: `t${last}`,
		items: rows.map(([position, key]) => ({ position: String(position), ordinal: "0", at: "1", value: { stop: { key, turn: null, cutoff: "1", completion: "completed" } } })),
		more: false, end: String(last), queued: { count: "0" },
		work: { actions: { stop: false, interrupt: null, decide: null }, state: { kind: "working", since: "1" } },
	});
}

/** The keys of the next `count` entries, or a failure that names `what` when none arrive in `ms`. */
async function keysWithin(watch: AsyncIterator<unknown>, count: number, what: string, ms = 3000): Promise<string[]> {
	let timer: NodeJS.Timeout | undefined;
	const deadline = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(`${what}: no rows within ${ms} ms`)), ms);
	});
	try {
		return await Promise.race([nextKeys(watch, count), deadline]);
	} finally {
		clearTimeout(timer);
	}
}

/** Releases the Host's queue (SIGUSR1 until the rows land) and returns the keys of the next `count` entries. */
async function releaseAndRead(rui: Rui, watch: AsyncIterator<unknown>, count: number, what: string, ms = 3000): Promise<string[]> {
	const pulse = setInterval(() => {
		if (rui.pid !== undefined) try { process.kill(rui.pid, "SIGUSR1"); } catch { /* the Host is restarting */ }
	}, 50);
	try {
		return await keysWithin(watch, count, what, ms);
	} finally {
		clearInterval(pulse);
	}
}

test("TS-14 the line's frames drive the reads of the watchers", { timeout: 60_000 }, async (t) => {
	await t.test("changed after a new page appears gives exactly the new rows, in order", async () => {
		const { rui, close } = await openScriptedLine(
			[[{ wait: true }, { type: "changed", session: SESSION }]],
			[{ kind: "reply", status: 200, body: emptyPage }, { kind: "reply", status: 200, body: pageOf([[1, "a1"], [2, "a2"]]) }],
		);
		const controller = new AbortController();
		try {
			const watch = rui.getSession(SESSION).watch({ signal: controller.signal });
			assert.deepEqual(await releaseAndRead(rui, watch, 2, "changed"), ["a1", "a2"]);
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("resync re-reads every cursor and gives the rows it finds", async () => {
		const { rui, close } = await openScriptedLine(
			[[{ wait: true }, { type: "resync" }]],
			[{ kind: "reply", status: 200, body: emptyPage }, { kind: "reply", status: 200, body: pageOf([[1, "r1"]]) }],
		);
		const controller = new AbortController();
		try {
			const watch = rui.getSession(SESSION).watch({ signal: controller.signal });
			assert.deepEqual(await releaseAndRead(rui, watch, 1, "resync"), ["r1"]);
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("a dropped line reconnects, re-watches and catches up from the cursor", async () => {
		const { rui, close } = await openScriptedLine(
			[[{ wait: true }, { drop: true }]],
			[{ kind: "reply", status: 200, body: pageOf([[1, "c1"]]) }, { kind: "reply", status: 200, body: pageOf([[2, "d2"]]) }],
		);
		const controller = new AbortController();
		try {
			const watch = rui.getSession(SESSION).watch({ signal: controller.signal });
			assert.deepEqual(await keysWithin(watch, 1, "catch-up"), ["c1"], "the first line delivers its catch-up");
			assert.deepEqual(await releaseAndRead(rui, watch, 1, "reconnect"), ["d2"]);
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("failed host_stopping, then the line closes, then the client reconnects to the restarted Host", async () => {
		const { rui, close } = await openScriptedLine(
			[[{ wait: true }, { type: "failed", code: "host_stopping" }, { exit: true }], []],
			[{ kind: "reply", status: 200, body: pageOf([[1, "h1"]]) }],
			[{ kind: "reply", status: 200, body: pageOf([[2, "h2"]]) }],
		);
		const controller = new AbortController();
		try {
			const watch = rui.getSession(SESSION).watch({ signal: controller.signal });
			assert.deepEqual(await keysWithin(watch, 1, "catch-up"), ["h1"], "the first Host's catch-up");
			const before = rui.pid;
			assert.deepEqual(await releaseAndRead(rui, watch, 1, "restart", 10_000), ["h2"]);
			assert.notEqual(rui.pid, before, "the rows come from the restarted Host");
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("a line refused with 503 line_capacity_exhausted ends its watchers with RuiRequestError, and later calls still succeed", async () => {
		const busy = JSON.stringify({ version: WIRE_VERSION, type: "busy", code: "line_capacity_exhausted" });
		const { rui, close } = await openScriptedLine([[{ refuse: { status: 503, body: busy } }]], []);
		const controller = new AbortController();
		try {
			const watch = rui.getSession(SESSION).watch({ signal: controller.signal });
			const failure = await failureOf(watch.next());
			assert.ok(failure instanceof RuiRequestError, `expected RuiRequestError, got ${String(failure)}`);
			assert.equal(failure.code, "line_capacity_exhausted");
			assert.ok(Buffer.isBuffer(await info(rui)), "a later call still reaches the Host");
		} finally {
			controller.abort();
			await close();
		}
	});
});
