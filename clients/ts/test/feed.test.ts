import assert from "node:assert/strict";
import { getEventListeners } from "node:events";
import { setImmediate as turn } from "node:timers/promises";
import { test } from "node:test";

import { RuiUnavailableError } from "../src/errors.ts";
import { listActivity, type FeedEntry } from "../src/feed.ts";
import { SessionNotifications } from "../src/notifications.ts";
import { Session, type Link } from "../src/sessions.ts";
import type { components } from "../src/wire.ts";

type Schemas = components["schemas"];

// Compiled by npm run check, including the negative assertions: no index signature
// or widened kind can satisfy these assignments and the exhaustive switch.
function narrowed(entry: FeedEntry): void {
	switch (entry.kind) {
		case "admission": case "user": case "received": {
			const state: "queued" | "applied" | "excluded" = entry.state;
			const admitted: string = entry.admittedAt;
			const sender: Schemas["NamedPeer"] | null = entry.sender;
			const text: string | undefined = entry.text;
			void [state, admitted, sender, text];
			break;
		}
		case "assistant": {
			const final: boolean = entry.final;
			void final;
			break;
		}
		case "call": {
			const ordinal: string = entry.callOrdinal;
			const fields: [Schemas["ActivityItemContent"], Schemas["ActivityItemContent"], Schemas["ActivityItemContent"]] = entry.fields;
			// @ts-expect-error Only top-level camelCase keys are exposed.
			void entry.call_ordinal;
			// @ts-expect-error Calls do not have the text-bearing row's extras.
			void entry.text;
			void [ordinal, fields];
			break;
		}
		case "tool_result": case "hosted_call": {
			const position: string | null = entry.presentation.publication_position;
			// @ts-expect-error Nested keys keep their generated wire spelling.
			void entry.presentation.publicationPosition;
			void position;
			break;
		}
		case "turn_ended": {
			const sessionId: string = entry.sessionId;
			// @ts-expect-error The wire session field is exposed as sessionId.
			void entry.session;
			const ending: "done" | "context_full" | "provider_refused" | "provider_unavailable" | "stopped" | "interrupted" | "failed" = entry.ending;
			const content: Schemas["ActivityItemContent"] | null = entry.content;
			void [sessionId, ending, content];
			break;
		}
		case "stop": {
			const completion: "pending" | "completed" = entry.completion;
			void completion;
			break;
		}
		case "sent": case "send_failed": {
			const target: Schemas["NamedPeer"] = entry.target;
			void target;
			break;
		}
		case "approval_requested": {
			const sessionId: string = entry.sessionId;
			// @ts-expect-error The wire session field is exposed as sessionId.
			void entry.session;
			const action: string = entry.action;
			const ordinal: string = entry.callOrdinal;
			// @ts-expect-error Other kinds' fields must not be accepted.
			void entry.final;
			void [sessionId, action, ordinal];
			break;
		}
		case "session_changed": {
			const field: "provider" | "model" | "instructions" | "tools" | "loaded_tools" | "permission_mode" | "output_schema" | "compaction_trigger" | "output_reservation" | "reasoning_effort" | "label" = entry.field;
			void field;
			break;
		}
		case "compacted": {
			const dropped: string = entry.dropped;
			void dropped;
			break;
		}
		default: {
			const exhaustive: never = entry;
			void exhaustive;
		}
	}
}

test("feed entry types narrow to each generated kind", () => { void narrowed; });

test("feed camelCases only row keys, preserving nested wire values and content references", async () => {
	const presentation = { description: "tool", code: "succeeded", publication_position: "7" };
	const content = { bytes: "2", sha256: "hash" };
	const rows = [
		{ position: "1", ordinal: "0", at: "1", value: { tool_result: { content, presentation } } },
		{ position: "2", ordinal: "0", at: "1", value: { hosted_call: { presentation } } },
		{ position: "3", ordinal: "0", at: "1", value: { approval_requested: { session: "ch1ld1", action: "8", operation: "9", call_ordinal: "10" } } },
	];
	const link: Link = { exchange: async (path) => path === "/v1/activity-content" ? Buffer.from("ok") : Buffer.from(JSON.stringify({ delta: "full", since: null, items: rows, more: false, end: "3" })) };
	const entries = [];
	for await (const entry of listActivity(link, "s")) entries.push(entry);
	assert.ok(entries[0]?.kind === "tool_result");
	assert.deepEqual(entries[0].presentation, presentation);
	assert.deepEqual(entries[0].content, content);
	assert.equal(entries[0].text, "ok");
	assert.equal(entries[0].contentBytes, "2");
	assert.ok(entries[1]?.kind === "hosted_call");
	assert.deepEqual(entries[1].presentation, presentation);
	assert.ok(entries[2]?.kind === "approval_requested");
	assert.equal(entries[2].callOrdinal, "10");
	assert.equal(entries[2].sessionId, "ch1ld1");
	assert.equal("session" in entries[2], false);
	assert.equal("call_ordinal" in entries[2], false);
});

function gate(): { promise: Promise<void>; resolve: () => void } {
	let resolve = () => {};
	const promise = new Promise<void>((done) => { resolve = done; });
	return { promise, resolve };
}

function fakeSession(state: Schemas["WorkStateJson"]["kind"] = "idle", queued = "0") {
	let pages = 0;
	let deliver = false;
	const link: Link = {
		activity: new SessionNotifications(),
		exchange: async (path) => {
			if (path === "/v1/inspect-session") return Buffer.from(JSON.stringify({
				session: { parent: null, label: null, model: "model-a", reasoning_effort: null, tools: [], permission_mode: "ask" },
				pending_messages: queued,
				work: { turn: null, operation: null, state: { kind: "idle", since: "1" }, latest_outcome: null },
			}));
			if (path !== "/v1/activity-page") {
				deliver = true;
				return Buffer.from(JSON.stringify({ answer: { status: "accepted", admission: "1" } }));
			}
			pages++;
			const items = deliver ? [{ position: String(pages), ordinal: "0", at: "1", value: { stop: { key: "k", turn: null, cutoff: "1", completion: "completed" } } }] : [];
			deliver = false;
			return Buffer.from(JSON.stringify({ delta: "full", since: null, items, more: false, end: String(pages), queued: { count: queued }, work: { state: { kind: state } } }));
		},
	};
	return { link, pages: () => pages };
}

for (const state of ["idle", "finished", "failed", "stopped"] as const) {
	test(`an empty ${state} feed makes no timed requests; a send from another handle wakes it`, async (t) => {
		t.mock.timers.enable({ apis: ["setTimeout"] });
		const fake = fakeSession(state);
		const controller = new AbortController();
		const feed = new Session(fake.link, "s").listActivity({ follow: true, signal: controller.signal });
		t.after(() => controller.abort());
		const pending = feed.next();
		await turn();
		assert.equal(fake.pages(), 1);
		t.mock.timers.tick(60_000);
		await turn();
		assert.equal(fake.pages(), 1, "idle must have no polling timer");
		// A different Session and a different client must not wake this follower.
		fake.link.activity?.notify("other");
		new SessionNotifications().notify("s");
		await turn();
		assert.equal(fake.pages(), 1);
		await new Session(fake.link, "s").send("hello", { idempotencyKey: "send" });
		await turn();
		assert.equal(fake.pages(), 2, "the write must wake the follower immediately");
		assert.equal((await pending).value?.kind, "stop");
		const sleeping = feed.next();
		await turn();
		controller.abort();
		assert.deepEqual(await sleeping, { done: true, value: undefined });
		await feed.return(undefined);
	});
}

for (const kind of ["send", "update", "decide", "interrupt", "stop"] as const) {
	test(`${kind} wakes every sleeping follower for the same Session`, async () => {
		const fake = fakeSession();
		const controller = new AbortController();
		const followers = [1, 2].map(() => new Session(fake.link, "s").listActivity({ follow: true, signal: controller.signal }));
		const pending = followers.map((feed) => feed.next());
		try {
			await turn();
			assert.equal(fake.pages(), 2);
			const writer = new Session(fake.link, "s");
			switch (kind) {
				case "send": await writer.send("hello", { idempotencyKey: "k" }); break;
				case "update": await writer.update({ label: "x" }); break;
				case "decide": await writer.decide("1", "allow"); break;
				case "interrupt": await writer.interrupt(); break;
				case "stop": await writer.stop(); break;
			}
			await turn();
			assert.ok(fake.pages() >= 4, "both followers must re-read");
		} finally {
			controller.abort();
			await Promise.all(pending);
			await Promise.all(followers.map((feed) => feed.return(undefined)));
		}
	});
}

test("a write racing the idle page reply is not lost", async () => {
	const fake = fakeSession();
	const original = fake.link.exchange;
	const entered = gate();
	const release = gate();
	let first = true;
	fake.link.exchange = async (...args) => {
		const reply = await original(...args);
		if (args[0] === "/v1/activity-page" && first) {
			first = false;
			entered.resolve();
			await release.promise;
		}
		return reply;
	};
	const controller = new AbortController();
	const feed = new Session(fake.link, "s").listActivity({ follow: true, signal: controller.signal });
	const pending = feed.next();
	try {
		await entered.promise;
		await new Session(fake.link, "s").send("racing", { idempotencyKey: "k" });
		release.resolve();
		assert.equal((await pending).value?.kind, "stop");
		assert.equal(fake.pages(), 2);
	} finally {
		controller.abort();
		release.resolve();
		await feed.return(undefined);
	}
});

for (const [state, queued] of [["working", "0"], ["idle", "1"]] as const) {
	test(`${state} with ${queued} queued polls at 250 ms rising to 2 s`, async (t) => {
		t.mock.timers.enable({ apis: ["setTimeout"] });
		const fake = fakeSession(state, queued);
		const controller = new AbortController();
		const pending = listActivity(fake.link, "s", { follow: true, signal: controller.signal }).next();
		try {
			await turn();
			let pages = 1;
			for (const delay of [250, 500, 1_000, 2_000, 2_000]) {
				t.mock.timers.tick(delay - 1);
				await turn();
				assert.equal(fake.pages(), pages);
				t.mock.timers.tick(1);
				await turn();
				assert.equal(fake.pages(), ++pages);
			}
		} finally {
			controller.abort();
			assert.equal((await pending).done, true);
		}
	});
}

test("closing a notification watch releases its subscription after an aborted wait", async () => {
	const notifications = new SessionNotifications();
	const watch = notifications.watch("s");
	const controller = new AbortController();
	const sleeping = watch.wait(watch.revision, controller.signal);
	controller.abort();
	await sleeping;
	watch.close();
	notifications.notify("s");
	assert.equal(watch.revision, 0, "closed subscriptions must no longer be retained");
});

test("a failed write does not wake an idle follower", async () => {
	const fake = fakeSession();
	const exchange = fake.link.exchange;
	fake.link.exchange = async (...args) => {
		if (args[0] === "/v1/message") throw new Error("write failed");
		return exchange(...args);
	};
	const controller = new AbortController();
	const pending = listActivity(fake.link, "s", { follow: true, signal: controller.signal }).next();
	try {
		await turn();
		await assert.rejects(new Session(fake.link, "s").send("no", { idempotencyKey: "k" }), /write failed/);
		await turn();
		assert.equal(fake.pages(), 1);
	} finally {
		controller.abort();
		assert.equal((await pending).done, true);
	}
});

test("a lifecycle failure rejects and releases all parked watches and their abort listeners", async () => {
	const notifications = new SessionNotifications();
	const controller = new AbortController();
	const watches = [notifications.watch("s"), notifications.watch("s"), notifications.watch("other")];
	const failure = new RuiUnavailableError("the Rui Host cannot restart");
	const pending = watches.map((watch) => assert.rejects(watch.wait(watch.revision, controller.signal), (error: unknown) => error === failure));
	assert.equal(getEventListeners(controller.signal, "abort").length, watches.length);
	notifications.fail(failure);
	await Promise.all(pending);
	assert.equal(getEventListeners(controller.signal, "abort").length, 0);
	for (const session of ["s", "other"]) notifications.notify(session);
	assert.deepEqual(watches.map((watch) => watch.revision), [0, 0, 0]);
});

test("failure during a page read is remembered even after a write races it", async () => {
	const notifications = new SessionNotifications();
	const watch = notifications.watch("s");
	const revision = watch.revision;
	notifications.notify("s");
	const failure = new RuiUnavailableError("the Rui client is closed");
	notifications.fail(failure);
	await assert.rejects(watch.wait(revision, undefined), (error: unknown) => error === failure);
});

test("releasing a failed watch again does not unregister a new follower after restart", async () => {
	const notifications = new SessionNotifications();
	const old = notifications.watch("s");
	notifications.fail(new RuiUnavailableError("the Rui Host could not restart"));
	const fresh = notifications.watch("s");
	old.close(); // The failed iterator's finally may run after a new follower starts.
	const controller = new AbortController();
	const pending = fresh.wait(fresh.revision, controller.signal);
	try {
		notifications.notify("s");
		assert.equal(fresh.revision, 1);
		await pending;
	} finally {
		controller.abort();
		fresh.close();
	}
});

test("follow retains its exhausted cursor and backoff across not_modified, and clears excluded tokens", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const requests: Schemas["ActivityPageRequest"][] = [];
	const replies = [
		{ delta: "full", since: "token-a", items: [], more: false, end: "9", queued: { count: "0" }, work: { state: { kind: "working" } } },
		{ version: "9", type: "activity_page", delta: "not_modified", since: "token-b" },
		{ delta: "full", since: null, items: [], more: false, end: "12", queued: { count: "0" }, work: { state: { kind: "working" } } },
		{ delta: "full", since: "token-c", items: [{ position: "13", ordinal: "2", at: "1", value: { stop: { key: "k", turn: null, cutoff: "1", completion: "completed" } } }], more: false, end: "14", queued: { count: "0" }, work: { state: { kind: "working" } } },
	];
	const link: Link = { exchange: async (_path, body) => {
		requests.push(JSON.parse(body("store")) as Schemas["ActivityPageRequest"]);
		assert.ok(replies.length > 0, "unexpected extra poll");
		return Buffer.from(JSON.stringify(replies.shift()));
	} };
	const controller = new AbortController();
	const feed = listActivity(link, "s", { follow: true, signal: controller.signal });
	const pending = feed.next();
	try {
		await turn();
		assert.equal(requests.length, 1);
		for (const [index, delay] of [250, 500, 1_000].entries()) {
			t.mock.timers.tick(delay - 1);
			await turn();
			assert.equal(requests.length, index + 1);
			t.mock.timers.tick(1);
			await turn();
			assert.equal(requests.length, index + 2);
		}
		const result = await pending;
		assert.equal(result.value?.position, "13");
		assert.equal(result.value?.ordinal, "2");
		assert.deepEqual(requests.map((request) => ({ position: request.position, ordinal: request.ordinal, end: request.end, since: "since" in request ? request.since : undefined })), [
			{ position: "0", ordinal: null, end: null, since: undefined },
			{ position: "9", ordinal: null, end: null, since: "token-a" },
			{ position: "9", ordinal: null, end: null, since: "token-b" },
			{ position: "12", ordinal: null, end: null, since: undefined },
		]);
	} finally {
		controller.abort();
		await pending;
		await feed.return(undefined);
	}
});

for (const follow of [false, true]) {
	test(`${follow ? "following" : "bounded"} pagination never reuses a token while pages remain unread`, async () => {
		const requests: Schemas["ActivityPageRequest"][] = [];
		const controller = new AbortController();
		const link: Link = { exchange: async (_path, body) => {
			requests.push(JSON.parse(body("store")) as Schemas["ActivityPageRequest"]);
			const first = requests.length === 1;
			const position = first ? "2" : "3";
			return Buffer.from(JSON.stringify({ delta: "full", since: "token", more: first, end: "9",
				items: [{ position, ordinal: "1", at: "1", value: { stop: { key: "k", turn: null, cutoff: "1", completion: "completed" } } }],
				queued: { count: "0" }, work: { state: { kind: "working" } },
			}));
		} };
		const feed = listActivity(link, "s", { follow, signal: controller.signal });
		try {
			assert.equal((await feed.next()).value?.position, "2");
			assert.equal((await feed.next()).value?.position, "3");
			assert.equal(requests.length, 2);
			assert.deepEqual(requests.map((request) => ({ position: request.position, ordinal: request.ordinal, end: request.end, since: "since" in request ? request.since : undefined })), [
				{ position: "0", ordinal: null, end: null, since: undefined },
				{ position: "2", ordinal: "1", end: follow ? null : "9", since: undefined },
			]);
		} finally {
			controller.abort();
			await feed.return(undefined);
		}
	});
}
