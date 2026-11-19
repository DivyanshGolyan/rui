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
	["preferences", { reasoningEffort: "high", permissionMode: "ask" }, { reasoning_effort: "high", permission_mode: "ask" }],
] as const;

async function checkCreationCombinations() {
	for (let mask = 0; mask < 1 << fields.length; mask++) {
		const chosen = fields.filter((_, index) => (mask & (1 << index)) !== 0);
		const spec: AgentSpec & { workspace: string } = { workspace: "/caller", model: "gpt-6.1-sol", ...Object.fromEntries(chosen.map(([name, value]) => [name, value])) };
		const expected = { workspace: "/caller", model: "gpt-6.1-sol", ...Object.fromEntries(chosen.map(([name, , value]) => [name, value])) };
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
}

async function checkEmptyAndNull() {
	const spec = { workspace: "/caller", model: "custom-model", tools: [], loadedTools: [], effort: null, compactAt: null } satisfies AgentSpec;
	const sessions = new Sessions({
		async exchange(path, build) {
			assert.equal(path, "/v1/configure");
			assert.deepEqual(JSON.parse(build("/store")).configuration, spec);
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	});
	await sessions.create(spec, { idempotencyKey: "chosen:empty" });
}

async function checkPresetOverrides() {
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
}


function checkSparsePreset() {
	const spec: AgentSpec = { model: "gpt-6.1-sol" };
	const launch = launchFor({ presets: { review: spec } }, "/runtime");
	try {
		assert.deepEqual(JSON.parse(launch.document.subarray(4).toString("utf8")).presets.review, { model: "gpt-6.1-sol" });
	} finally {
		launch.document.fill(0);
	}
}

async function checkParent() {
	for (const spec of [{ parent: "p4rent", model: "gpt-6.1-sol" }, { parent: "p4rent", preset: "review" }] as const) {
		const sessions = new Sessions({
			async exchange(path, build) {
				assert.equal(path, "/v1/configure");
				const request = JSON.parse(build("/store"));
				assert.deepEqual(request.configuration, { parent: "p4rent", ...("model" in spec ? { model: spec.model } : {}) });
				assert.equal(request.preset, "preset" in spec ? spec.preset : undefined);
				return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
			},
		});
		await sessions.create(spec, { idempotencyKey: "chosen:parent" });
	}
}


async function checkEmptyPreferences() {
	const sessions = new Sessions({
		async exchange(_path, build) {
			assert.deepEqual(JSON.parse(build("/store")).configuration, { workspace: "/caller", model: "gpt-6.1-sol", preferences: {} });
			return Buffer.from(JSON.stringify({ answer: { status: "accepted", session: "abc123" } }));
		},
	});
	await sessions.create({ workspace: "/caller", model: "gpt-6.1-sol", preferences: {} }, { idempotencyKey: "chosen:preferences" });
}

test("TS-8 creation_intent", async () => {
	await checkCreationCombinations();
	await checkEmptyAndNull();
	await checkPresetOverrides();
	checkSparsePreset();
	await checkParent();
	await checkEmptyPreferences();
});
