import assert from "node:assert/strict";
import { test } from "node:test";

import { listActivity } from "../src/feed.ts";
import { RuiUnavailableError } from "../src/errors.ts";
import { Session } from "../src/sessions.ts";
import { fakeFeed, nextKeys, scriptedLink, settle } from "./scripted-line.ts";

// TS-14 (docs/invariants/cli-inspection.md): a followed Session yields each committed row once, in order, reading only
// when the line nudges it. These cases drive `Follows` through a scripted line and a fake feed.

test("TS-14 a commit to a watched Session gives exactly its new rows, in order and without duplicates", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a", "b");
	const watch = new Session(line.link, "k7m2qx").watch();
	try {
		assert.deepEqual(await nextKeys(watch, 2), ["a", "b"]);
		feed.append("k7m2qx", "c", "d");
		line.changed("k7m2qx");
		assert.deepEqual(await nextKeys(watch, 2), ["c", "d"]);
		line.changed("k7m2qx");
		await settle();
		feed.append("k7m2qx", "e");
		line.changed("k7m2qx");
		assert.deepEqual(await nextKeys(watch, 1), ["e"], "a nudge with nothing new adds no rows");
	} finally {
		await watch.return(undefined);
	}
});

test("TS-14 a Session with more than one page of new rows reads them all, in order, on one nudge", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	const keys = Array.from({ length: 20 }, (_, index) => `k${index}`);
	feed.append("k7m2qx", ...keys);
	const watch = new Session(line.link, "k7m2qx").watch();
	try {
		assert.deepEqual(await nextKeys(watch, 20), keys);
	} finally {
		await watch.return(undefined);
	}
});

test("TS-14 two watchers on one Session share one line and one feed read", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a");
	const session = new Session(line.link, "k7m2qx");
	const first = session.watch();
	const second = session.watch();
	try {
		const pending = [first.next(), second.next()];
		const [one, two] = await Promise.all(pending);
		assert.equal(one?.value?.kind, "stop");
		assert.equal(two?.value?.kind, "stop");
		assert.deepEqual(line.lines, [["k7m2qx"]], "the second watcher adds no line frame");
		assert.equal(feed.reads(), 1, "one read serves both watchers at the same cursor");
	} finally {
		await first.return(undefined);
		await second.return(undefined);
	}
});

test("TS-14 resync re-reads every watched cursor and loses nothing", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a");
	const watch = new Session(line.link, "k7m2qx").watch();
	try {
		assert.deepEqual(await nextKeys(watch, 1), ["a"]);
		feed.append("k7m2qx", "b", "c");
		line.resync();
		assert.deepEqual(await nextKeys(watch, 2), ["b", "c"]);
	} finally {
		await watch.return(undefined);
	}
});

test("TS-14 an idle watch makes no feed reads until a nudge", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a");
	const controller = new AbortController();
	const watch = new Session(line.link, "k7m2qx").watch({ signal: controller.signal });
	try {
		assert.deepEqual(await nextKeys(watch, 1), ["a"]);
		const idle = feed.reads();
		await settle(50);
		assert.equal(feed.reads(), idle, "an idle watch must not poll");
		const pending = watch.next();
		await settle(50);
		assert.equal(feed.reads(), idle, "a waiting watch must not poll");
		feed.append("k7m2qx", "b");
		line.changed("k7m2qx");
		assert.deepEqual(await Promise.all([pending]).then(([next]) => [(next.value as { key?: string }).key]), ["b"]);
	} finally {
		controller.abort();
		await watch.return(undefined);
	}
});

test("TS-14 listActivity with follow yields the same rows as watch", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a", "b", "c");
	const controller = new AbortController();
	const watch = new Session(line.link, "k7m2qx").watch({ signal: controller.signal });
	const follow = listActivity(line.link, "k7m2qx", { follow: true, signal: controller.signal });
	try {
		const fromWatch = await nextKeys(watch, 3);
		const fromFollow = await nextKeys(follow, 3);
		assert.deepEqual(fromFollow, fromWatch);
		assert.deepEqual(fromWatch, ["a", "b", "c"]);
	} finally {
		controller.abort();
		await watch.return(undefined);
		await follow.return(undefined);
	}
});

test("TS-14 the last watcher leaving closes the line; an earlier one leaving keeps it", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a");
	const session = new Session(line.link, "k7m2qx");
	const controller = new AbortController();
	const first = session.watch({ signal: controller.signal });
	const second = session.watch({ signal: controller.signal });
	try {
		await Promise.all([first.next(), second.next()]);
		await first.return(undefined);
		assert.deepEqual(line.lines.at(-1), ["k7m2qx"], "the line stays open for the second watcher");
		await second.return(undefined);
		assert.deepEqual(line.lines.at(-1), [], "the last watcher closes the line");
	} finally {
		controller.abort();
	}
});

test("TS-14 a Session's first watcher opens the line with the watched set, and a second Session adds itself to it", { timeout: 5000 }, async () => {
	const feed = fakeFeed(["k7m2qx", "09azvw"]);
	const line = scriptedLink(feed.exchange);
	feed.append("k7m2qx", "a");
	feed.append("09azvw", "b");
	const controller = new AbortController();
	const first = new Session(line.link, "k7m2qx").watch({ signal: controller.signal });
	const second = new Session(line.link, "09azvw").watch({ signal: controller.signal });
	try {
		assert.deepEqual(await Promise.all([first.next(), second.next()]).then((all) => all.map((next) => next.value?.kind)), ["stop", "stop"]);
		assert.deepEqual(line.lines, [["k7m2qx"], ["k7m2qx", "09azvw"]]);
	} finally {
		controller.abort();
	}
});

test("TS-14 a failed client ends every watcher with its error and closes the line", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	const watch = new Session(line.link, "k7m2qx").watch();
	const parked = watch.next();
	await settle();
	const failure = new RuiUnavailableError("the Rui client is closed");
	line.follows.fail(failure);
	await assert.rejects(parked, (error: unknown) => error === failure);
	assert.deepEqual(line.lines.at(-1), []);
	await watch.return(undefined);
});

test("TS-14 a Session id outside the Host's grammar is refused before the line opens", { timeout: 5000 }, async () => {
	const line = scriptedLink(fakeFeed().exchange);
	await assert.rejects(new Session(line.link, "not-an-id").watch().next(), RangeError);
	assert.deepEqual(line.lines, [], "the Host would close a line whose watch set breaks its grammar");
});

test("TS-14 a read failure ends only the failed Session's watchers and drops it from the line", { timeout: 5000 }, async () => {
	const feed = fakeFeed(["bad000", "g00d00"]);
	const exchange = feed.exchange;
	const line = scriptedLink(async (path, build) => {
		if (JSON.parse(build("store")).session === "bad000") throw new RuiUnavailableError("the feed read failed");
		return exchange(path, build);
	});
	feed.append("g00d00", "g");
	const controller = new AbortController();
	const bad = new Session(line.link, "bad000").watch({ signal: controller.signal });
	const good = new Session(line.link, "g00d00").watch({ signal: controller.signal });
	try {
		const goodFirst = good.next();
		await assert.rejects(bad.next(), RuiUnavailableError);
		assert.deepEqual(line.lines.at(-1), ["g00d00"]);
		assert.deepEqual(await Promise.all([goodFirst]).then(([next]) => [(next.value as { key?: string }).key]), ["g"]);
	} finally {
		controller.abort();
	}
});

test("TS-14 a released watcher from a failed client does not remove a newer watcher of the same Session", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	const line = scriptedLink(feed.exchange);
	const session = new Session(line.link, "k7m2qx");
	const old = session.watch();
	const oldPending = old.next();
	await settle();
	line.follows.fail(new RuiUnavailableError("the Rui Host could not restart"));
	await assert.rejects(oldPending, RuiUnavailableError);
	const controller = new AbortController();
	const fresh = session.watch({ signal: controller.signal });
	const freshPending = fresh.next();
	await settle();
	await old.return(undefined);
	feed.append("k7m2qx", "fresh");
	line.changed("k7m2qx");
	try {
		assert.deepEqual(await Promise.all([freshPending]).then(([entry]) => [(entry.value as { key?: string }).key]), ["fresh"]);
	} finally {
		controller.abort();
	}
});

test("TS-14 a nudge racing an in-flight page read is not lost", { timeout: 5000 }, async () => {
	const feed = fakeFeed();
	let release: () => void = () => {};
	let entered: () => void = () => {};
	const enteredRead = new Promise<void>((resolve) => { entered = resolve; });
	let first = true;
	const line = scriptedLink(async (path, build) => {
		const reply = await feed.exchange(path, build);
		if (first) {
			first = false;
			entered();
			await new Promise<void>((resolve) => { release = resolve; });
		}
		return reply;
	});
	const watch = new Session(line.link, "k7m2qx").watch();
	const pending = watch.next();
	await enteredRead;
	feed.append("k7m2qx", "racing");
	line.changed("k7m2qx");
	release();
	try {
		assert.deepEqual(await Promise.all([pending]).then(([entry]) => [(entry.value as { key?: string }).key]), ["racing"]);
	} finally {
		await watch.return(undefined);
	}
});

test("TS-14 a nudge that finds no change keeps the cursor and moves only the token", { timeout: 5000 }, async () => {
	const requests: { position: string; since?: string }[] = [];
	const replies: unknown[] = [
		{ delta: "full", since: "token-a", items: [], more: false, end: "9", queued: { count: "0" }, work: { attention: null, group: "working", actions: { stop: false, interrupt: null, decide: null }, state: { kind: "working" } } },
		{ version: "24", type: "activity_page", delta: "not_modified", since: "token-b" },
		{ delta: "full", since: "token-c", items: [{ position: "13", ordinal: "2", at: "1", value: { stop: { key: "k13", turn: null, cutoff: "1", completion: "completed" } } }], more: false, end: "14", queued: { count: "0" }, work: { attention: null, group: "working", actions: { stop: false, interrupt: null, decide: null }, state: { kind: "working" } } },
	];
	const line = scriptedLink(async (_path, body) => {
		const request = JSON.parse(body("store")) as { position: string; since?: string };
		requests.push({ position: request.position, ...("since" in request ? { since: request.since } : {}) });
		return Buffer.from(JSON.stringify(replies.shift()));
	});
	const controller = new AbortController();
	const watch = new Session(line.link, "k7m2qx").watch({ signal: controller.signal });
	const pending = watch.next();
	try {
		await settle();
		assert.equal(requests.length, 1);
		line.changed("k7m2qx");
		await settle();
		assert.equal(requests.length, 2, "the nudge read is answered not_modified");
		line.changed("k7m2qx");
		assert.equal(((await pending).value as { key?: string }).key, "k13");
		assert.deepEqual(requests, [
			{ position: "0" },
			{ position: "9", since: "token-a" },
			{ position: "9", since: "token-b" },
		]);
	} finally {
		controller.abort();
		await watch.return(undefined);
	}
});
