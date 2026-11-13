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
		if (codec?.kind === "secret") {
			if (typeof value === "string") return { value };
			if (value && typeof value === "object" && Object.hasOwn(value, "env")) environmentSource?.((value as { env: unknown }).env, `${path}.env`);
		}
		if (codec?.kind === "bytes" && value instanceof Uint8Array) return { hex: Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("hex") };
		if (!codec?.fields || value === null || typeof value !== "object" || Array.isArray(value)) return value;
		return Object.fromEntries(Object.entries(value).map(([name, field]) => [name, visit(field, codec.fields && Object.hasOwn(codec.fields, name) ? codec.fields[name] : codec.fields?.["*"], path ? `${path}.${name}` : name)]));
	}
	return visit(value, SETTINGS_KINDS, "") as components["schemas"]["HostSettings"];
}
