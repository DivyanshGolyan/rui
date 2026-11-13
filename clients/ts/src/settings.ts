// Friendly inputs are mechanically derived from the generated document type.
// Runtime codecs come from annotations on that same schema, never a field list.
import { SETTINGS_KINDS } from "./settings-kinds.ts";
import type { AgentSpec } from "./sessions.ts";
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
