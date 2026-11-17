import assert from "node:assert/strict";
import { test } from "node:test";

import { launchFor } from "../src/client.ts";
import { Sessions, type AgentSpec, type Link, type SessionCreate } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

const fields = [
	["tools", ["web_search", "bash", "bash"], ["bash", "web_search"]],
	["loadedTools", ["web_search", "bash", "web_search"], ["bash", "web_search"]],
	["permissionMode", "ask", "ask"],
	["effort", "low", "low"],
	["compactAt", 100000, 100000],
] as const;

test("creation sends only chosen settings for every omitted and explicit field combination", async () => {
	for (let mask = 0; mask < 1 << fields.length; mask++) {
		const chosen = fields.filter((_, index) => (mask & (1 << index)) !== 0);
		const spec: AgentSpec = { model: "gpt-6.1-sol", ...Object.fromEntries(chosen.map(([name, value]) => [name, value])) };
		const expected = { model: "gpt-6.1-sol", ...Object.fromEntries(chosen.map(([name, , value]) => [name, value])) };
		const before = structuredClone(spec);
		const idempotencyKey = `chosen:${mask}`;
		const link: Link = {
			async exchange(path, build) {
				assert.equal(path, "/v1/configure");
				assert.deepEqual(JSON.parse(build("/store")), {
					version: WIRE_VERSION, kind: "configure", store: "/store", key: idempotencyKey,
					session: "", configuration: expected,
				}, `chosen fields mask ${mask}`);
				return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
			},
		};
		assert.equal((await new Sessions(link).create(spec, { idempotencyKey })).id, "abc123");
		const launch = launchFor({ presets: { review: spec } }, "/runtime");
		try {
			assert.deepEqual(JSON.parse(launch.document.subarray(4).toString("utf8")).presets.review, expected);
		} finally {
			launch.document.fill(0);
		}
		assert.deepEqual(spec, before, "serializing chosen settings preserves caller input");
	}
});

test("creation preserves explicit empty tools and null effort without completing omissions", async () => {
	const spec: AgentSpec = { model: "custom-model", tools: [], loadedTools: [], effort: null };
	const sessions = new Sessions({
		async exchange(path, build) {
			assert.equal(path, "/v1/configure");
			assert.deepEqual(JSON.parse(build("/store")).configuration, spec);
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	});
	await sessions.create(spec, { idempotencyKey: "chosen:empty" });
});

test("a named preset forwards only the chosen overrides", async () => {
	const spec: SessionCreate = { preset: "review", permissionMode: "bypass", effort: null, tools: [] };
	const sessions = new Sessions({
		async exchange(path, build) {
			assert.equal(path, "/v1/configure");
			assert.deepEqual(JSON.parse(build("/store")), {
				version: WIRE_VERSION, kind: "configure", store: "/store", key: "chosen:preset", session: "",
				preset: "review", configuration: { permissionMode: "bypass", effort: null, tools: [] },
			});
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	});
	await sessions.create(spec, { idempotencyKey: "chosen:preset" });
});
