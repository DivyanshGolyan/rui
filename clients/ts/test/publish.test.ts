// The publication order comes from the tarballs' manifests, never from a list
// of package names, so a new platform or a renamed tarball needs no change here.
import assert from "node:assert/strict";
import { test } from "node:test";

// @ts-expect-error: a plain JavaScript release script with no type declarations.
import { publicationOrder } from "../scripts/publish.mjs";

const client = (platforms: string[]) => ({
	file: "/x/anything-named.tgz",
	name: "ruicode",
	version: "1.2.3",
	dependencies: Object.fromEntries(platforms.map((name) => [name, "1.2.3"])),
});
const platform = (name: string, file = `/x/${name}.tgz`) => ({ file, name, version: "1.2.3", dependencies: {} });

test("platform packages publish before the client, whatever the tarballs are called", () => {
	const order = publicationOrder([client(["ruicode-b", "ruicode-a"]), platform("ruicode-b", "/x/renamed.tgz"), platform("ruicode-a")], "1.2.3");
	assert.deepEqual(order.map((m: { name: string }) => m.name), ["ruicode-a", "ruicode-b", "ruicode"]);
	assert.equal(order[1].file, "/x/renamed.tgz");
});

test("an added platform is published with no change to the plan", () => {
	const names = ["ruicode-a", "ruicode-b", "ruicode-new"];
	const order = publicationOrder([client(names), ...names.map((name) => platform(name))], "1.2.3");
	assert.deepEqual(order.map((m: { name: string }) => m.name), [...names, "ruicode"]);
});

test("a same-release dependency without a tarball is refused before anything publishes", () => {
	assert.throws(() => publicationOrder([client(["ruicode-a", "ruicode-missing"]), platform("ruicode-a")], "1.2.3"), /ruicode-missing@1.2.3/);
});

test("dependencies outside the release are left to npm", () => {
	const order = publicationOrder([{ ...client([]), dependencies: { leftpad: "^1.0.0" } }], "1.2.3");
	assert.deepEqual(order.map((m: { name: string }) => m.name), ["ruicode"]);
});
