// Fails when src/wire.ts is not what openapi-typescript makes from the
// checked-in openapi.json, then type-checks the package.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { settingsKinds } from "./generate-settings.mjs";

const directory = mkdtempSync(join(tmpdir(), "rui-wire-"));
try {
	const fresh = join(directory, "wire.ts");
	execFileSync("npx", ["openapi-typescript", "../../openapi.json", "--output", fresh], { stdio: "inherit" });
	if (readFileSync(fresh, "utf8") !== readFileSync("src/wire.ts", "utf8")) {
		console.error("src/wire.ts is stale: run `npm run generate` in clients/ts and commit the result");
		process.exit(1);
	}
} finally {
	rmSync(directory, { recursive: true, force: true });
}
if (settingsKinds(JSON.parse(readFileSync("../../openapi.json", "utf8"))) !== readFileSync("src/settings-kinds.ts", "utf8")) {
	console.error("src/settings-kinds.ts is stale: run `npm run generate` in clients/ts");
	process.exit(1);
}
execFileSync("npx", ["tsc", "-p", "."], { stdio: "inherit" });
