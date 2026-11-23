import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError, RuiWaitTimeoutError } from "../src/errors.ts";
import { reloadTools, type Link } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

/** Advances mocked time one step at a time, letting each poll's replies settle before the next timer is due. */
async function advance(t: { mock: { timers: { tick(ms: number): void } } }, ms: number, step = 250): Promise<void> {
	for (let elapsed = 0; elapsed < ms; elapsed += step) {
		await new Promise((resolve) => setImmediate(resolve));
		t.mock.timers.tick(step);
	}
	await new Promise((resolve) => setImmediate(resolve));
}

const HOST = "11".repeat(16);
const RESTARTED_HOST = "22".repeat(16);

type Row = { server: string; state: "idle" | "listing" | "waiting"; last: "never" | "listed" | "failed" | "collision"; finished: string; tools: string };

/** A Link whose tools-reload reply comes from `reloadInstance` and whose status replies come from `statusInstance`. */
function fakeLink(asked: { server: string; generation: string }[], statuses: Row[][], reloadInstance = HOST, statusInstance = HOST) {
	const bodies: { path: string; body: unknown }[] = [];
	let polls = 0;
	const link: Link = {
		exchange: async (path, build) => {
			const body = JSON.parse(build('store"\n'));
			bodies.push({ path, body });
			if (path === "/v1/control/tools-reload") {
				return Buffer.from(JSON.stringify({ version: WIRE_VERSION, type: "tools_reload_reply", instance: reloadInstance, asked }));
			}
			assert.equal(path, "/v1/tools-status");
			const next = statuses[Math.min(polls, statuses.length - 1)];
			polls += 1;
			return Buffer.from(JSON.stringify({ version: WIRE_VERSION, type: "tools_status", instance: statusInstance, servers: next }));
		},
	};
	return { link, bodies, polls: () => polls };
}

test("reloadTools asks every server, polls tools_status until each generation lands, and reports outcomes", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
	const waiting: Row[] = [
		{ server: "docs", state: "listing", last: "listed", finished: "1", tools: "10" },
		{ server: "notes", state: "waiting", last: "failed", finished: "1", tools: "0" },
	];
	const landed: Row[] = [
		{ server: "docs", state: "idle", last: "listed", finished: "2", tools: "12" },
		{ server: "notes", state: "idle", last: "failed", finished: "2", tools: "0" },
	];
	const { link, bodies, polls } = fakeLink(
		[{ server: "docs", generation: "2" }, { server: "notes", generation: "2" }],
		[waiting, waiting, landed],
	);
	const result = reloadTools(link);
	await advance(t, 500);
	assert.deepEqual(await result, [
		{ server: "docs", outcome: "listed", tools: 12 },
		{ server: "notes", outcome: "failed", tools: 0 },
	]);
	assert.equal(polls(), 3);
	assert.deepEqual(bodies[0], { path: "/v1/control/tools-reload", body: { version: WIRE_VERSION, kind: "tools_reload", store: 'store"\n' } });
	assert.deepEqual(bodies[1], { path: "/v1/tools-status", body: { version: WIRE_VERSION, kind: "tools_status", store: 'store"\n' } });
});

test("reloadTools names one server when asked and treats a finished generation above the ask as landed", async () => {
	const { link, bodies } = fakeLink(
		[{ server: "docs", generation: "3" }],
		[[{ server: "docs", state: "idle", last: "collision", finished: "4", tools: "0" }]],
	);
	assert.deepEqual(await reloadTools(link, "docs"), [{ server: "docs", outcome: "collision", tools: 0 }]);
	assert.deepEqual(bodies[0]?.body, { version: WIRE_VERSION, kind: "tools_reload", store: 'store"\n', server: "docs" });
});

test("reloadTools with no configured servers resolves to an empty list without polling", async () => {
	const { link, polls } = fakeLink([], []);
	assert.deepEqual(await reloadTools(link), []);
	assert.equal(polls(), 0);
});

test("reloadTools rejects an invalid reply when an asked server has no status row", async () => {
	const { link } = fakeLink(
		[{ server: "docs", generation: "2" }, { server: "notes", generation: "2" }],
		[[{ server: "docs", state: "idle", last: "listed", finished: "2", tools: "1" }]],
	);
	await assert.rejects(reloadTools(link), (error: unknown) => error instanceof RuiRequestError && error.code === "invalid_response");
});

test("reloadTools rejects an invalid reply when a landed server reports never", async () => {
	const { link } = fakeLink(
		[{ server: "docs", generation: "2" }],
		[[{ server: "docs", state: "idle", last: "never", finished: "2", tools: "0" }]],
	);
	await assert.rejects(reloadTools(link), (error: unknown) => error instanceof RuiRequestError && error.code === "invalid_response");
});

test("reloadTools in a restarted Host waits out finished 0 and lands once its startup list has finished", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
	const startingUp: Row[] = [{ server: "docs", state: "listing", last: "never", finished: "0", tools: "0" }];
	const startupListed: Row[] = [{ server: "docs", state: "idle", last: "listed", finished: "1", tools: "7" }];
	const { link, polls } = fakeLink([{ server: "docs", generation: "5" }], [startingUp, startupListed], HOST, RESTARTED_HOST);
	const result = reloadTools(link, "docs");
	await advance(t, 500);
	assert.deepEqual(await result, [{ server: "docs", outcome: "listed", tools: 7 }]);
	assert.equal(polls(), 2);
});

test("reloadTools rejects with RuiWaitTimeoutError after 60 seconds naming the servers still listing", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
	const stuck: Row[] = [{ server: "docs", state: "listing", last: "never", finished: "0", tools: "0" }];
	const { link } = fakeLink([{ server: "docs", generation: "1" }], [stuck]);
	const result = reloadTools(link).then(
		() => assert.fail("expected a timeout"),
		(error: unknown) => error,
	);
	await advance(t, 60_000);
	const error = await result;
	assert.ok(error instanceof RuiWaitTimeoutError);
	assert.equal(error.code, "wait_timed_out");
	assert.match(error.message, /docs/);
});
