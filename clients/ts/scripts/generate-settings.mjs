// Derive runtime input codecs from the same schema that generates wire.ts.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function settingsKinds(document) {
	function merge(left, right) {
		if (!right) return left;
		const fields = { ...left?.fields };
		for (const [key, value] of Object.entries(right.fields ?? {})) fields[key] = merge(fields[key], value);
		return { ...(left?.kind ? { kind: left.kind } : {}), ...(right.kind ? { kind: right.kind } : {}), ...(Object.keys(fields).length ? { fields } : {}) };
	}
	function visit(schema) {
		if (!schema || typeof schema !== "object") return undefined;
		if (schema.$ref) return visit(schema.$ref.slice(2).split("/").reduce((value, key) => value[key], document));
		let result = schema["x-rui-kind"] ? { kind: schema["x-rui-kind"] } : undefined;
		for (const variant of [...(schema.oneOf ?? []), ...(schema.anyOf ?? []), ...(schema.allOf ?? [])]) result = merge(result, visit(variant));
		for (const [name, field] of Object.entries(schema.properties ?? {})) {
			const child = visit(field);
			if (child) result = merge(result, { fields: { [name]: child } });
		}
		const child = visit(schema.additionalProperties);
		if (child) result = merge(result, { fields: { "*": child } });
		return result;
	}
	const root = document.components.schemas.HostSettings;
	if (!root) throw new Error("HostSettings schema is missing");
	const kinds = visit(root);
	if (!kinds) throw new Error("HostSettings schema input codecs are missing");
	return `// Generated from openapi.json by scripts/generate-settings.mjs. Do not edit.\nexport const SETTINGS_KINDS = ${JSON.stringify(kinds, null, "\t")} as const;\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	writeFileSync(new URL("../src/settings-kinds.ts", import.meta.url), settingsKinds(JSON.parse(readFileSync(new URL("../../../openapi.json", import.meta.url), "utf8"))));
}
