import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError } from "../src/errors.ts";
import { Session, Sessions, type Link, type ListSessionsOptions } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";
import { scriptedLink, settle } from "./scripted-line.ts";

test("archive and unarchive use one durable intent route", async () => {
	const bodies: unknown[] = [];
	const link: Link = {
		exchange: async (path, build) => {
			assert.equal(path, "/v1/control/session-archive");
			const body = JSON.parse(build("/store"));
			bodies.push(body);
			return Buffer.from(JSON.stringify({
				answer: { status: "accepted", replayed: false, session: "k7m2qx", archived: body.archived },
				completion: { status: body.archived ? "pending" : "completed" },
			}));
		},
	};
	const session = new Session(link, "k7m2qx");
	assert.deepEqual(await session.archive({ idempotencyKey: "archive:1" }), { archived: true, completion: "pending" });
	assert.deepEqual(await session.unarchive({ idempotencyKey: "restore:1" }), { archived: false, completion: "completed" });
	assert.deepEqual(bodies, [true, false].map((archived) => ({
		version: WIRE_VERSION, kind: "session_archive", store: "/store", session: "k7m2qx", archived,
		key: archived ? "archive:1" : "restore:1",
	})));
});

test("archive refusals preserve server errors and start no work", async () => {
	for (const code of ["archive_pending", "unknown_session", "idempotency_key_conflict"]) {
		let requests = 0;
		const session = new Session({
			exchange: async (path) => {
				requests++;
				assert.equal(path, "/v1/control/session-archive");
				return Buffer.from(JSON.stringify({ answer: { status: code === "idempotency_key_conflict" ? "conflict" : "rejected", code }, completion: { status: "unavailable" } }));
			},
		}, "k7m2qx");
		await assert.rejects(session.unarchive(), (error: unknown) => error instanceof RuiRequestError && error.code === code);
		assert.equal(requests, 1);
	}
});

test("session lists keep archive visibility across pages and expose independent metadata", async () => {
	for (const archive of [undefined, "active", "archived", "all"] as const) {
		const requests: { archive: string; workspace: null; after: string; ceiling: string }[] = [];
		const sessions = new Sessions({ exchange: async (path, build) => {
			assert.equal(path, "/v1/list-sessions");
			requests.push(JSON.parse(build("/store")));
			return Buffer.from(JSON.stringify({
				sessions: [{ reference: requests.length === 1 ? "k7m2qx" : "09azvw", label: null, parent: null, creator: null, work: { state: { kind: "idle" }, actions: { stop: false, interrupt: null, decide: null } }, archive_state: "archived", state_change_at: "1", subtree_state_change_at: "1", descendant_count: "0", descendant_needs_you_count: "0" }],
				next: requests.length === 1 ? { after: "8", ceiling: "23" } : null,
			}));
		} });
		const options: ListSessionsOptions | undefined = archive === undefined ? undefined : { archive };
		assert.deepEqual(await sessions.list(options), ["09azvw", "k7m2qx"].map((id) => ({ id, label: null, parent: null, creator: null, state: "idle", canStop: false, decide: null, interruptTarget: null, archiveState: "archived", stateChangeAt: "1", subtreeStateChangeAt: "1", descendantCount: "0", descendantNeedsYouCount: "0" })));
		assert.deepEqual(requests.map(({ archive, workspace, after, ceiling }) => ({ archive, workspace, after, ceiling })), [
			{ archive: archive ?? "active", workspace: null, after: "0", ceiling: "0" },
			{ archive: archive ?? "active", workspace: null, after: "8", ceiling: "23" },
		]);
	}
});

test("archival reaches an idle watcher only through the Host's nudge, and submits no Message", { timeout: 5000 }, async () => {
	const controller = new AbortController();
	let pageReads = 0;
	let archiveRequests = 0;
	const line = scriptedLink(async (path) => {
		if (path === "/v1/control/session-archive") {
			archiveRequests++;
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", archived: true }, completion: { status: "completed" } }));
		}
		assert.equal(path, "/v1/activity-page");
		pageReads++;
		return Buffer.from(JSON.stringify({ delta: "full", since: "token", end: "0", items: [], more: false, aggregates: { as_of: "0", call_activity: { total: "0", entries: [] }, queued: { count: "0" } }, work: { actions: { stop: false, interrupt: null, decide: null }, state: { kind: "idle" } } }));
	});
	const session = new Session(line.link, "k7m2qx");
	const followed = session.watch({ signal: controller.signal }).next();
	try {
		await settle();
		assert.equal(pageReads, 1);
		await session.archive();
		await settle();
		assert.equal(pageReads, 1, "a local write is not a nudge");
		line.changed("k7m2qx");
		await settle();
		assert.equal(pageReads, 2, "the Host's nudge is what reads the feed");
		assert.equal(archiveRequests, 1);
	} finally {
		controller.abort();
		assert.equal((await followed).done, true);
	}
});

test("an accepted archive reply still needs an available settlement status", async () => {
	const session = new Session({ exchange: async () => Buffer.from(JSON.stringify({
		answer: { status: "accepted", archived: true }, completion: { status: "unavailable" },
	})) }, "k7m2qx");
	await assert.rejects(session.archive(), (error: unknown) => error instanceof RuiRequestError && error.code === "invalid_response");
});
