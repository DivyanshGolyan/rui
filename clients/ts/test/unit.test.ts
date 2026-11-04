import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { encodeFrame, startError } from "../src/client.ts";
import { RuiStartError } from "../src/errors.ts";
import { WIRE_VERSION } from "../src/transport.ts";

test("the wire version is the one openapi.json describes", () => {
	const document = JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"));
	assert.equal(WIRE_VERSION, document.info.version);
});

test("a launch frame is a big-endian length and the JSON", () => {
	const frame = encodeFrame({ v: 1, store: "/s" });
	const json = '{"v":1,"store":"/s"}';
	assert.equal(frame.readUInt32BE(0), json.length);
	assert.equal(frame.subarray(4).toString("utf8"), json);
});

test("the refusal line becomes a RuiStartError", () => {
	const refusal = startError('{"rui_start_error":{"code":"store_locked","message":"another Host holds this Store"}}\n');
	assert.ok(refusal instanceof RuiStartError);
	assert.equal(refusal.code, "store_locked");
	assert.equal(refusal.message, "another Host holds this Store");
	assert.equal(startError(""), undefined);
	assert.equal(startError("not json\n"), undefined);
});
