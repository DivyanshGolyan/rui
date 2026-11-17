import assert from "node:assert/strict";
import { test } from "node:test";

import { launchFor } from "../src/client.ts";
import { Sessions, type AgentSpec, type Link, type SessionCreate } from "../src/sessions.ts";
import { WIRE_VERSION } from "../src/transport.ts";

const fields = [
	["model", "gpt-6.1-sol", "gpt-6.1-sol"],
	["tools", ["web_search", "bash", "bash"], ["bash", "web_search"]],
	["loadedTools", ["web_search", "bash", "web_search"], ["bash", "web_search"]],
	["permissionMode", "ask", "ask"],
	["effort", "low", "low"],
	["compactAt", 100000, 100000],
	["preferences", { reasoningEffort: "high", permissionMode: "ask" }, { reasoning_effort: "high", permission_mode: "ask" }],
] as const;

test("creation sends only chosen settings for every omitted and explicit field combination", async () => {
	for (let mask = 0; mask < 1 << fields.length; mask++) {
		const chosen = fields.filter((_, index) => (mask & (1 << index)) !== 0);
		const spec: AgentSpec & { workspace: string } = { workspace: "/caller", ...Object.fromEntries(chosen.map(([name, value]) => [name, value])) };
		const expected = { workspace: "/caller", ...Object.fromEntries(chosen.map(([name, , value]) => [name, value])) };
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

test("creation preserves empty tools and Host default requests without completing omissions", async () => {
	const spec = { workspace: "/caller", model: "custom-model", tools: [], loadedTools: [], effort: null, compactAt: null } satisfies AgentSpec;
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


test("presets keep sparse settings until creation resolves a Workspace", () => {
	const spec: AgentSpec = {};
	const launch = launchFor({ presets: { review: spec } }, "/runtime");
	try {
		assert.deepEqual(JSON.parse(launch.document.subarray(4).toString("utf8")).presets.review, {});
	} finally {
		launch.document.fill(0);
	}
});

test("child creation forwards the parent without inventing a Workspace or provider", async () => {
	for (const spec of [{ parent: "p4rent" }, { parent: "p4rent", preset: "review" }] as const) {
		const sessions = new Sessions({
			async exchange(path, build) {
				assert.equal(path, "/v1/configure");
				const request = JSON.parse(build("/store"));
				assert.deepEqual(request.configuration, { parent: "p4rent" });
				assert.equal(request.preset, "preset" in spec ? spec.preset : undefined);
				return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
			},
		});
		await sessions.create(spec, { idempotencyKey: "chosen:parent" });
	}
});


test("creation preserves an empty preferences object", async () => {
	const sessions = new Sessions({
		async exchange(_path, build) {
			assert.deepEqual(JSON.parse(build("/store")).configuration, { workspace: "/caller", preferences: {} });
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	});
	await sessions.create({ workspace: "/caller", preferences: {} }, { idempotencyKey: "chosen:preferences" });
});
