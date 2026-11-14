// Friendly inputs are mechanically derived from the generated document type.
// Runtime codecs come from annotations on that same schema, never a field list.
import { SETTINGS_KINDS } from "./settings-kinds.ts";
import { agentSpec, type AgentSpec } from "./sessions.ts";
import { RuiStartError } from "./errors.ts";
import type { components } from "./wire.ts";

type Input<T> = T extends { value: string } ? T | string
	: T extends { hex: string } ? T | Uint8Array
	: T extends readonly (infer Item)[] ? readonly Input<Item>[]
	: T extends object ? { [Key in keyof T]: Input<T[Key]> }
	: T;

/** The generated Host document, with pipe-only secret strings and byte-array paths. */
export type HostSettings = Omit<Input<components["schemas"]["HostSettings"]>, "presets"> & {
	/** Uses the same friendly Session spec and writer as sessions.create. */
	presets?: Record<string, AgentSpec>;
};

interface Kind {
	readonly kind?: string;
	readonly fields?: { readonly [name: string]: Kind };
}

/** Normalize only generated schema leaves. Arbitrary preset JSON is not interpreted. */
export function pipeSettings(value: HostSettings, environmentSource?: (name: unknown, path: string) => void): components["schemas"]["HostSettings"] {
	function visit(value: unknown, codec: Kind | undefined, path: string): unknown {
		if (codec?.kind === "secret" && typeof value === "string") return { value };
		if (codec?.kind === "bytes") {
			if (value instanceof Uint8Array) return { hex: Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("hex") };
			if (value !== null && typeof value === "object") {
				// Project only this byte leaf once, preserving toJSON(key) and omitted-field semantics.
				const key = path.slice(path.lastIndexOf(".") + 1);
				const projected = JSON.parse(JSON.stringify({ [key]: value })) as Record<string, unknown>;
				return Object.hasOwn(projected, key) ? projected[key] : undefined;
			}
			return value;
		}
		if (!codec?.fields || value === null || typeof value !== "object") return value;
		if (Array.isArray(value)) {
			// Invalid record arrays retain their shape, without species, iterators or serializers.
			const elements = new Array<unknown>(value.length);
			Object.setPrototypeOf(elements, null);
			for (let index = 0; index < value.length; index++) {
				if (Object.hasOwn(value, index)) elements[index] = value[index];
			}
			return elements;
		}
		// Metadata-owned records are own data; callable fields cannot rewrite later decisions.
		const normalized = Object.fromEntries(Object.entries(value).filter(([, field]) => typeof field !== "function").map(([name, field]) => [name, visit(field, codec.fields && Object.hasOwn(codec.fields, name) ? codec.fields[name] : codec.fields?.["*"], path ? `${path}.${name}` : name)]));
		if (codec.kind === "secret" && Object.hasOwn(normalized, "env")) environmentSource?.(normalized.env, `${path}.env`);
		return normalized;
	}
	return visit(value, SETTINGS_KINDS, "") as components["schemas"]["HostSettings"];
}

/** Launch projection is owned alongside the document, not by child supervision. */
export interface PreparedSettings {
	document: components["schemas"]["HostSettings"];
	interfaceDir: NonNullable<NonNullable<components["schemas"]["HostSettings"]["interface"]>["dir"]>;
	detached: boolean;
}

/** Preserve client defaults and friendly preset encoding after canonical normalization. */
export function prepareSettings(settings: HostSettings, runtimeDir: string, env: NodeJS.ProcessEnv): PreparedSettings {
	let document = pipeSettings(settings, (source, path) => {
		const name = environmentName(source, path);
		if (name === undefined) return;
		const value = process.env[name];
		if (value !== undefined) env[name] = value;
	});
	let interfaceDir: PreparedSettings["interfaceDir"] = runtimeDir;
	let detached = false;
	if (document !== null && typeof document === "object" && !Array.isArray(document)) {
		if (Object.hasOwn(document, "presets") && document.presets !== undefined) {
			// Presets retain their existing friendly spec writer after settings normalization.
			const presets = document.presets as HostSettings["presets"];
			document = { ...document, presets: Object.fromEntries(Object.entries(presets!).map(([name, spec]) => [name, agentSpec(spec) as components["schemas"]["AgentSpec"]])) };
		}
		const supplied = Object.hasOwn(document, "interface") && document.interface !== undefined ? document.interface : {};
		if (supplied !== null && typeof supplied === "object" && !Array.isArray(supplied)) {
			// Choose client defaults once, from canonical own data; invalid groups reach the Host unchanged.
			const selected = {
				...supplied,
				...(!Object.hasOwn(supplied, "dir") || supplied.dir == null ? { dir: runtimeDir } : {}),
				...(!Object.hasOwn(supplied, "lifetime") || supplied.lifetime === undefined ? { lifetime: "stdin" as const } : {}),
			};
			document = { ...document, interface: selected };
			interfaceDir = selected.dir!; // The single default choice above supplies every omitted/null directory.
			detached = selected.lifetime !== "stdin";
		}
	}
	return { document, interfaceDir, detached };
}

/** Consume the byte codec's canonical JSON value before allowing any Node environment lookup.
 * Malformed values stay in the document for Host refusal; Host bounds remain its own. */
function environmentName(source: unknown, path: string): string | undefined {
	let name: string;
	if (typeof source === "string") name = source;
	else {
		if (source === null || typeof source !== "object") return undefined;
		const fields = Object.keys(source);
		if (fields.length !== 1 || fields[0] !== "hex") return undefined;
		const hex = (source as { hex?: unknown }).hex;
		if (typeof hex !== "string") return undefined;
		if (hex.length % 2 !== 0 || /[^0-9a-f]/.test(hex)) return undefined;
		try {
			name = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(Buffer.from(hex, "hex"));
		} catch {
			throw new RuiStartError("settings_invalid", `${path}: Node requires UTF-8 environment names; use a file source for OS-byte names`);
		}
	}
	// Node truncates NUL and replaces lone UTF-16 surrogates; neither may choose another key.
	return name.length !== 0 && !/[\0=\uD800-\uDFFF]/u.test(name) ? name : undefined;
}
