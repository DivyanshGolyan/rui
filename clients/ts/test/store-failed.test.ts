import assert from "node:assert/strict";
import { once } from "node:events";
import { test } from "node:test";

import { RuiRequestError, RuiStoreFailedError, RuiUnavailableError } from "../src/index.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import { canonical, dispatched, emptyPage, failureOf, info, openScripted, openScriptedLine, unrelatedBusy, unrelatedInvocation, type Step } from "./scripted-host.ts";

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
		const controller = new AbortController();
		try {
			const watch = rui.getSession("k7m2qx").watch({ signal: controller.signal });
			const parked = failureOf(watch.next());
			const latch = await failureOf(info(rui));
			assert.ok(latch instanceof RuiStoreFailedError);
			assert.equal(await parked, latch);
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("a line that closes twice without answering a watch set ends its watchers, rather than reconnecting forever", async () => {
		const { rui, close } = await openScriptedLine([[{ silent: true }], [{ silent: true }]], [{ kind: "reply", status: 200, body: emptyPage }]);
		const controller = new AbortController();
		try {
			const watch = rui.getSession("k7m2qx").watch({ signal: controller.signal });
			const failure = await failureOf(watch.next());
			assert.ok(failure instanceof RuiUnavailableError, `expected the closed-line failure, got ${String(failure)}`);
			assert.match(failure.message, /closed its line twice/);
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("a store_failed line frame latches the watchers parked on it and every call", async () => {
		const { rui, close } = await openScriptedLine([[{ type: "failed", code: "store_failed" }]], [{ kind: "reply", status: 200, body: emptyPage }]);
		const controller = new AbortController();
		try {
			const watch = rui.getSession("k7m2qx").watch({ signal: controller.signal });
			const parked = await failureOf(watch.next());
			assert.ok(parked instanceof RuiStoreFailedError, "the line's fence latches the watcher");
			assert.equal(await failureOf(info(rui)), parked);
		} finally {
			controller.abort();
			await close();
		}
	});

	await t.test("a canonical_store_failure refusal of the line latches the parked watcher and the next call with the same error", async () => {
		const { rui, close } = await openScriptedLine([[{ refuse: { status: 500, body: canonical } }]], []);
		const controller = new AbortController();
		try {
			const watch = rui.getSession("k7m2qx").watch({ signal: controller.signal });
			const parked = await failureOf(watch.next());
			assert.ok(parked instanceof RuiStoreFailedError, `expected the latch, got ${String(parked)}`);
			assert.equal(parked.code, "store_failed");
			assert.equal(await failureOf(info(rui)), parked);
		} finally {
			controller.abort();
			await close();
		}
	});

	const dispatchOutcomes: { name: string; steps: Step[]; latched: boolean; restarting?: boolean }[] = [
		{
			name: "a 503 dispatch_fenced followed by a store_fenced line and an exit latches RuiStoreFailedError, and the Host is not restarted",
			steps: [{ kind: "reply_then_fence", status: 503, body: dispatched }],
			latched: true,
			restarting: false,
		},
		{
			name: "a 503 dispatch_fenced followed by a plain exit, as a stop or cleanup phase does, is its own error and the Host restarts",
			steps: [{ kind: "reply_then_exit", status: 503, body: dispatched }],
			latched: false,
			restarting: true,
		},
		{
			name: "a 503 dispatch_fenced from a Host still running past the grace is its own error and does not latch",
			steps: [{ kind: "reply", status: 503, body: dispatched }],
			latched: false,
		},
	];
	for (const outcome of dispatchOutcomes) {
		await t.test(outcome.name, async () => {
			const { rui, close } = await openScripted(outcome.steps, []);
			try {
				const exited = outcome.restarting === undefined ? undefined : once(rui, "exit");
				const first = await failureOf(info(rui));
				if (outcome.latched) {
					assert.ok(first instanceof RuiStoreFailedError);
					assert.equal(first.code, "store_failed");
				} else {
					assert.ok(first instanceof RuiRequestError);
					assert.equal(first.code, "dispatch_fenced");
					assert.ok(!(first instanceof RuiStoreFailedError));
				}
				if (exited) {
					const [event] = await exited;
					assert.equal(event.restarting, outcome.restarting);
				}
				const later = await failureOf(info(rui));
				if (outcome.latched) assert.equal(later, first);
				else assert.equal(later, undefined, "a Host that is not fenced still answers");
			} finally {
				await close();
			}
		});
	}

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
