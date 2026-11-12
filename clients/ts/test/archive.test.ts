import assert from "node:assert/strict";
import { test } from "node:test";

import { RuiRequestError } from "../src/errors.ts";
import { SessionNotifications } from "../src/notifications.ts";
import { Session, Sessions, type Link, type ListSessionsOptions } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

test("archive and unarchive use one durable intent route and wake idle followers", async () => {
	const activity = new SessionNotifications();
	const watch = activity.watch("k7m2qx");
	const bodies: unknown[] = [];
	const link: Link = {
		activity,
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
	try {
		const session = new Session(link, "k7m2qx");
		let woken = watch.wait(watch.revision, undefined);
		assert.deepEqual(await session.archive({ idempotencyKey: "archive:1" }), { archived: true, completion: "pending" });
		await woken;
		assert.equal(watch.revision, 1);
		woken = watch.wait(watch.revision, undefined);
		assert.deepEqual(await session.unarchive({ idempotencyKey: "restore:1" }), { archived: false, completion: "completed" });
		await woken;
		assert.equal(watch.revision, 2);
		assert.deepEqual(bodies, [true, false].map((archived) => ({
			version: WIRE_VERSION, kind: "session_archive", store: "/store", session: "k7m2qx", archived,
			key: archived ? "archive:1" : "restore:1",
		})));
	} finally {
		watch.close();
	}
});

test("archive refusals preserve server errors without waking followers or starting work", async () => {
	for (const code of ["archive_pending", "unknown_session", "idempotency_key_conflict"]) {
		const activity = new SessionNotifications();
		const watch = activity.watch("k7m2qx");
		let requests = 0;
		const session = new Session({
			activity,
			exchange: async (path) => {
				requests++;
				assert.equal(path, "/v1/control/session-archive");
				return Buffer.from(JSON.stringify({ answer: { status: code === "idempotency_key_conflict" ? "conflict" : "rejected", code }, completion: { status: "unavailable" } }));
			},
		}, "k7m2qx");
		try {
			await assert.rejects(session.unarchive(), (error: unknown) => error instanceof RuiRequestError && error.code === code);
			assert.equal(watch.revision, 0);
			assert.equal(requests, 1);
		} finally {
			watch.close();
		}
	}
});

test("session lists keep archive visibility across pages and expose independent metadata", async () => {
	for (const archive of [undefined, "active", "archived", "all"] as const) {
		const requests: { archive: string; workspace: null; after: string; ceiling: string }[] = [];
		const sessions = new Sessions({ exchange: async (path, build) => {
			assert.equal(path, "/v1/list-sessions");
			requests.push(JSON.parse(build("/store")));
			return Buffer.from(JSON.stringify({
				sessions: [{ reference: requests.length === 1 ? "k7m2qx" : "09azvw", label: null, parent: null, work: { state: { kind: "idle" } }, archive_state: "archived" }],
				next: requests.length === 1 ? { after: "8", ceiling: "23" } : null,
			}));
		} });
		const options: ListSessionsOptions | undefined = archive === undefined ? undefined : { archive };
		assert.deepEqual(await sessions.list(options), ["09azvw", "k7m2qx"].map((id) => ({ id, label: null, parent: null, state: "idle", archiveState: "archived" })));
		assert.deepEqual(requests.map(({ archive, workspace, after, ceiling }) => ({ archive, workspace, after, ceiling })), [
			{ archive: archive ?? "active", workspace: null, after: "0", ceiling: "0" },
			{ archive: archive ?? "active", workspace: null, after: "8", ceiling: "23" },
		]);
	}
});

test("archival wakes an idle activity iterator without submitting a Message", async () => {
	const activity = new SessionNotifications();
	const controller = new AbortController();
	let initialRead!: () => void;
	const ready = new Promise<void>((resolve) => { initialRead = resolve; });
	let pageReads = 0;
	let archiveRequests = 0;
	const session = new Session({
		activity,
		exchange: async (path) => {
			if (path === "/v1/control/session-archive") {
				archiveRequests++;
				return Buffer.from(JSON.stringify({ answer: { status: "accepted", archived: true }, completion: { status: "completed" } }));
			}
			assert.equal(path, "/v1/activity-page");
			pageReads++;
			if (pageReads === 1) initialRead();
			else controller.abort();
			return Buffer.from(JSON.stringify({ delta: "full", since: "token", end: "0", items: [], more: false, queued: { count: "0" }, work: { state: { kind: "idle" } } }));
		},
	}, "k7m2qx");
	const iterator = session.listActivity({ follow: true, signal: controller.signal });
	const followed = iterator.next();
	await ready;
	await session.archive();
	assert.equal((await followed).done, true);
	assert.equal(pageReads, 2);
	assert.equal(archiveRequests, 1);
});

test("an accepted archive reply still needs an available settlement status", async () => {
	const activity = new SessionNotifications();
	const watch = activity.watch("k7m2qx");
	try {
		const session = new Session({ activity, exchange: async () => Buffer.from(JSON.stringify({
			answer: { status: "accepted", archived: true }, completion: { status: "unavailable" },
		})) }, "k7m2qx");
		await assert.rejects(session.archive(), (error: unknown) => error instanceof RuiRequestError && error.code === "invalid_response");
		assert.equal(watch.revision, 0);
	} finally {
		watch.close();
	}
});
