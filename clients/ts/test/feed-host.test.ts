import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { EventEmitter, once } from "node:events";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { createSecureServer } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";

import { Rui } from "../src/index.ts";

const binary = process.env.RUI_BINARY;

function answer(text: string, index: number): string {
	const item = {
		type: "message", id: `msg-${index}`, status: "completed", role: "assistant", phase: "final_answer",
		content: [{ type: "output_text", text, annotations: [] }],
	};
	return [
		{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: item.id } },
		{ type: "response.output_item.done", output_index: 0, item },
		{ type: "response.completed", response: { id: `resp-${index}`, status: "completed", model: "model-a", output: [item], usage: { input_tokens: 7, output_tokens: 11, total_tokens: 18 } } },
	].map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
}

interface Fixture {
	rui: Rui;
	session: Awaited<ReturnType<Rui["sessions"]["create"]>>;
	requests: string[];
	paths: string[];
	/** Stops the client and the provider, and removes the fixture's directory. */
	close(): Promise<void>;
}

/** A local Host over a scripted provider, with one Session that answers each Message with `answer N`. */
async function openFixture(root: string): Promise<Fixture> {
	const cert = join(root, "cert.pem");
	const key = join(root, "key.pem");
	execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1", "-days", "1"], { stdio: "pipe" });
	const provider = createSecureServer({ key: readFileSync(key), cert: readFileSync(cert) });
	const requests: string[] = [];
	const paths: string[] = [];
	provider.on("stream", (stream, headers) => {
		let body = "";
		stream.on("data", (chunk: Buffer) => { body += chunk.toString("utf8"); });
		stream.on("end", () => {
			paths.push(String(headers[":path"]));
			if (headers[":path"] === "/v1/models") {
				stream.respond({ ":status": 200, "content-type": "application/json" });
				stream.end(JSON.stringify({ object: "list", data: [{ id: "model-a", object: "model", owned_by: "fixture" }] }));
				return;
			}
			if (headers[":path"] !== "/v1/responses") {
				stream.respond({ ":status": 404 });
				stream.end();
				return;
			}
			requests.push(body);
			stream.respond({ ":status": 200, "content-type": "text/event-stream" });
			stream.end(answer(`answer ${requests.length}`, requests.length));
		});
	});
	provider.listen(0, "127.0.0.1");
	await once(provider, "listening");
	const address = provider.address();
	assert.ok(address && typeof address !== "string");
	const rui = await Rui.connect({
		store: { sqlite: { dir: join(root, "store") } },
		providers: { openai: { endpoint: `https://127.0.0.1:${address.port}/v1/responses`, key: "local-fixture-only" } },
		network: { caFile: cert },
	}, { binary: binary ?? "rui" });
	const session = await rui.sessions.create({
		connection: "openai", model: "model-a", effort: null, compactAt: 100000,
		workspace: tmpdir(), tools: [], permissionMode: "ask",
	}, { idempotencyKey: "feed:session" });
	return {
		rui, session, requests, paths,
		close: async () => {
			try {
				await rui.close();
			} finally {
				provider.close();
			}
		},
	};
}

test("follow wakes for two local sends and makes no requests between them while idle", { skip: binary ? false : "set RUI_BINARY to a built rui", timeout: 30_000 }, async (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-feed-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const controller = new AbortController();
	t.signal.addEventListener("abort", () => controller.abort(), { once: true });
	const fixture = await openFixture(root);
	const { rui, session, requests, paths } = fixture;
	let consume: Promise<void> | undefined;
	try {
		const events = new EventEmitter();
		let pages = 0;
		let idle = false;
		const exchange = rui.exchange.bind(rui);
		rui.exchange = async (...args) => {
			const reply = await exchange(...args);
			if (args[0] === "/v1/activity-page") {
				pages++;
				const page = JSON.parse(reply.toString("utf8"));
				if (page.delta === "full") {
					idle = page.queued.count === "0" && ["idle", "finished", "failed", "stopped"].includes(page.work.state.kind);
				}
				if (idle && (page.delta === "not_modified" || page.items.length === 0)) setImmediate(() => events.emit("idle"));
			}
			return reply;
		};
		const texts: string[] = [];
		const firstIdle = once(events, "idle", { signal: controller.signal });
		consume = (async () => {
			for await (const entry of session.listActivity({ follow: true, signal: controller.signal })) {
				if (entry.kind === "assistant") {
					texts.push(entry.text ?? "");
					events.emit("answer");
				}
				if (entry.kind === "turn_ended") {
					assert.equal(entry.ending, "done", `unexpected turn ending: ${JSON.stringify(entry)}`);
					// The rows of a commit are their own read; the Session is idle once its turn's last row is delivered.
					events.emit("idle");
				}
			}
		})();
		const unexpectedEnd = consume.then(() => {
			if (!controller.signal.aborted) throw new Error("following feed ended before cancellation");
		});
		await Promise.race([firstIdle, unexpectedEnd]);
		// The Host nudges once per commit around creation, and each nudge is read. Those reads settle before the idle window.
		await sleep(600);
		const initialPages = pages;
		await sleep(600);
		assert.equal(pages, initialPages, "initial idle follower must not poll");

		for (let index = 1; index <= 2; index++) {
			const answered = once(events, "answer", { signal: controller.signal });
			const idle = once(events, "idle", { signal: controller.signal });
			await rui.getSession(session.id).send(`message ${index}`, { idempotencyKey: `feed:message:${index}` });
			await Promise.race([Promise.all([answered, idle]), unexpectedEnd]);
			assert.deepEqual(texts, Array.from({ length: index }, (_, i) => `answer ${i + 1}`));
			const atIdle = pages;
			await sleep(2_200);
			assert.equal(pages, atIdle, "completed idle follower must not poll");
		}
		assert.deepEqual(texts, ["answer 1", "answer 2"]);
		assert.equal(requests.length, 2);
		assert.ok(paths.every((path) => path === "/v1/models" || path === "/v1/responses"));
		controller.abort();
		await consume;
	} finally {
		controller.abort();
		try {
			await consume;
		} finally {
			await fixture.close();
		}
	}
});

test("a followed feed re-watches its Session after the Host is killed and restarted", { skip: binary ? false : "set RUI_BINARY to a built rui", timeout: 90_000 }, async (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-restart-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const controller = new AbortController();
	const fixture = await openFixture(root);
	const { rui, session, requests } = fixture;
	let consume: Promise<void> | undefined;
	try {
		const events = new EventEmitter();
		const texts: string[] = [];
		consume = (async () => {
			for await (const entry of session.listActivity({ follow: true, signal: controller.signal })) {
				if (entry.kind === "assistant") texts.push(entry.text ?? "");
				if (entry.kind === "turn_ended") events.emit("turn");
			}
		})();
		const turns = () => once(events, "turn", { signal: controller.signal });
		let turn = turns();
		await rui.getSession(session.id).send("message 1", { idempotencyKey: "restart:1" });
		await turn;
		assert.deepEqual(texts, ["answer 1"]);

		const exited = once(rui, "exit");
		process.kill(rui.pid as number, "SIGKILL");
		const [exit] = await exited;
		assert.equal(exit?.restarting, true, "the Host is restarted, not latched");

		// The new Host's line opens with the watched set, so its nudge reads the Session from the cursor and delivers the answer.
		turn = turns();
		await rui.getSession(session.id).send("message 2", { idempotencyKey: "restart:2" });
		await turn;
		assert.deepEqual(texts, ["answer 1", "answer 2"]);
		assert.equal(requests.length, 2);
	} finally {
		controller.abort();
		try {
			await consume;
		} finally {
			await fixture.close();
		}
	}
});
