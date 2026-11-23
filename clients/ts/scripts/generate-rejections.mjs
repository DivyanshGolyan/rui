import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** The Host catalog's plain sentence for each saved rejection code, as openapi.json publishes it. */
export function rejectionSentences(document) {
	const sentences = document["x-rui-rejections"];
	if (!sentences || typeof sentences !== "object") throw new Error("openapi.json has no x-rui-rejections");
	return `// Generated from openapi.json by scripts/generate-rejections.mjs. Do not edit.\nexport const REJECTION_SENTENCES: Readonly<Record<string, string>> = ${JSON.stringify(sentences, null, "\t")};\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	writeFileSync(new URL("../src/rejections.ts", import.meta.url), rejectionSentences(JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"))));
}
