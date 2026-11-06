// A real Host and a local, deterministic OpenAI-compatible provider; no credentials or network service.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { EventEmitter, once } from "node:events";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createSecureServer } from "node:http2";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
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

test("follow wakes for two local sends and makes no requests between them while idle", { skip: binary ? false : "set RUI_BINARY to a built rui", timeout: 30_000 }, async (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "rui-ts-feed-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const cert = join(root, "cert.pem");
	const key = join(root, "key.pem");
	execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1", "-days", "1"], { stdio: "pipe" });
	// System trust uses Apple SecTrust on macOS, not SSL_CERT_FILE.
	// Give the real Host explicit trust in only this fixture certificate on every platform.
	const quote = (value: string) => "'" + value.replaceAll("'", "'\"'\"'") + "'";
	const wrapper = join(root, "rui-with-test-ca");
	writeFileSync(wrapper, `#!/bin/sh\nexec ${quote(resolve(binary ?? "rui"))} "$@" --provider-ca-file ${quote(cert)}\n`, { mode: 0o700 });
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
	const controller = new AbortController();
	t.signal.addEventListener("abort", () => controller.abort(), { once: true });
	let rui: Rui | undefined;
	let consume: Promise<void> | undefined;
	try {
		rui = await Rui.connect({
			database: join(root, "store"), binary: wrapper,
			provider: { baseUrl: `https://127.0.0.1:${address.port}/v1`, key: "local-fixture-only" },
		});
		const session = await rui.sessions.create({
			provider: "openai", model: "model-a", effort: null, compactAt: 100000,
			workspace: tmpdir(), tools: [], permissionMode: "ask",
		}, { idempotencyKey: "feed:session" });
		const events = new EventEmitter();
		let pages = 0;
		let idlePages = 0;
		const exchange = rui.exchange.bind(rui);
		rui.exchange = async (...args) => {
			const reply = await exchange(...args);
			if (args[0] === "/v1/activity-page") {
				pages++;
				const page = JSON.parse(reply.toString("utf8"));
				if (page.items.length === 0 && page.queued.count === "0" && ["idle", "finished", "failed", "stopped"].includes(page.work.state.kind)) {
					idlePages++;
					// Let the iterator consume the reply before the observation reaches the test.
					setImmediate(() => events.emit("idle"));
				}
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
				if (entry.kind === "turn_ended") assert.equal(entry.ending, "done", `unexpected turn ending: ${JSON.stringify(entry)}`);
			}
		})();
		const unexpectedEnd = consume.then(() => {
			if (!controller.signal.aborted) throw new Error("following feed ended before cancellation");
		});
		await Promise.race([firstIdle, unexpectedEnd]);
		const initialPages = pages;
		await sleep(600); // Observation window: longer than the initial 250 ms polling interval.
		assert.equal(pages, initialPages, "initial idle follower must not poll");

		for (let index = 1; index <= 2; index++) {
			const answered = once(events, "answer", { signal: controller.signal });
			const idle = once(events, "idle", { signal: controller.signal });
			// Deliberately use a new handle, not the handle the follower belongs to.
			await rui.getSession(session.id).send(`message ${index}`, { idempotencyKey: `feed:message:${index}` });
			// An empty dormant page is not proof that the follower yielded the answer.
			await Promise.race([Promise.all([answered, idle]), unexpectedEnd]);
			assert.deepEqual(texts, Array.from({ length: index }, (_, i) => `answer ${i + 1}`));
			const atIdle = pages;
			await sleep(2_200); // Also catches the old implementation's capped 2 s polling.
			assert.equal(pages, atIdle, "completed idle follower must not poll");
		}
		assert.deepEqual(texts, ["answer 1", "answer 2"]);
		assert.equal(requests.length, 2);
		assert.ok(paths.every((path) => path === "/v1/models" || path === "/v1/responses"));
		assert.equal(idlePages, 3);
		controller.abort();
		await consume;
	} finally {
		controller.abort();
		try {
			await consume;
		} finally {
			await rui?.close();
			provider.close();
			rmSync(root, { recursive: true, force: true });
		}
	}
});
