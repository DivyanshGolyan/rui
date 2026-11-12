// Publishes the tarballs pack.mjs wrote to npm (D125, D186). The tarballs'
// own manifests are the inventory: each package is published after the
// packages it depends on, so the client's optional platform dependencies
// already resolve when it appears. A version npm already has is skipped, so a
// rerun after a partial publication finishes the rest.
//
//   node scripts/publish.mjs <dir>
import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Orders manifests ({file, name, version, dependencies}) so every package
 * comes after the packages in the set it depends on. A dependency on a
 * package of the same release that has no tarball is refused, since the
 * published package would point at a version that never appears. */
export function publicationOrder(manifests, release) {
	const byName = new Map(manifests.map((manifest) => [manifest.name, manifest]));
	if (byName.size !== manifests.length) throw new Error("two tarballs carry the same package name");
	const ordered = [];
	const placed = new Set();
	const visiting = new Set();
	const place = (manifest) => {
		if (placed.has(manifest.name)) return;
		if (visiting.has(manifest.name)) throw new Error(`dependency cycle at ${manifest.name}`);
		visiting.add(manifest.name);
		for (const [name, version] of Object.entries(manifest.dependencies).sort(([a], [b]) => a.localeCompare(b))) {
			const dependency = byName.get(name);
			if (dependency !== undefined) place(dependency);
			else if (version === release) throw new Error(`${manifest.name} needs ${name}@${version}, which has no tarball`);
		}
		visiting.delete(manifest.name);
		placed.add(manifest.name);
		ordered.push(manifest);
	};
	for (const manifest of [...manifests].sort((a, b) => a.name.localeCompare(b.name))) place(manifest);
	return ordered;
}

function manifestOf(file) {
	const json = JSON.parse(execFileSync("tar", ["-xzOf", file, "package/package.json"], { encoding: "utf8" }));
	return {
		file,
		name: json.name,
		version: json.version,
		dependencies: { ...json.dependencies, ...json.optionalDependencies },
	};
}

function published(name, version) {
	try {
		return execFileSync("npm", ["view", `${name}@${version}`, "version"], { encoding: "utf8" }).trim() === version;
	} catch {
		return false;
	}
}

function main(args) {
	const [directory] = args;
	if (!directory) {
		console.error("usage: node scripts/publish.mjs <dir>");
		process.exit(2);
	}
	const files = readdirSync(directory).filter((name) => name.endsWith(".tgz")).map((name) => resolve(join(directory, name)));
	const manifests = files.map(manifestOf);
	const versions = new Set(manifests.map((manifest) => manifest.version));
	if (versions.size !== 1) throw new Error(`expected one release version, found ${[...versions].join(", ") || "none"}`);
	const [release] = versions;
	for (const manifest of publicationOrder(manifests, release)) {
		if (published(manifest.name, manifest.version)) {
			console.log(`${manifest.name}@${manifest.version} is already on npm`);
			continue;
		}
		execFileSync("npm", ["publish", "--access", "public", "--provenance", manifest.file], { stdio: "inherit" });
	}
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
