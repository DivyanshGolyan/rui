
import { REJECTION_SENTENCES } from "./rejections.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];
type Reply = Schemas[Extract<keyof Schemas, `${string}Reply`>];
type Answer<T> = T extends { answer: infer A } ? A : never;
type Code<T> = T extends { code: infer C extends string } ? C : never;
type Status<T> = T extends { status: infer S extends string } ? S : never;

export type RequestAnswer = Answer<Reply>;
export type RequestRejectionCode = Code<RequestAnswer>;
export type RequestErrorCode = RequestRejectionCode | Schemas["ErrorReply"]["code"];
type RequestErrorType = Schemas["ErrorReply"]["type"] | Status<Extract<RequestAnswer, { code: string }>>;
type StartErrorCode = Schemas["StartError"]["rui_start_error"]["code"];

/** A setting a new Session lacked, named by a `missing_settings` rejection. */
export type MissingSetting = NonNullable<Extract<RequestAnswer, { missing: unknown }>["missing"]>[number];

/**
 * Rui rejected one request. `code` is the Host's rejection code. The message is the Host's advisory detail when it sent
 * one, else the Host catalog's plain sentence for `code`, with any missing settings and the code.
 */
export class RuiRequestError extends Error {
	override readonly name = "RuiRequestError";
	readonly code: RequestErrorCode;
	/** The Host's error class, such as `invocation_error` or `busy`. */
	readonly type: RequestErrorType;
	/** Every setting a new Session lacked, set exactly when `code` is `missing_settings`. */
	readonly missing: readonly MissingSetting[] | undefined;

	constructor(type: RequestErrorType, code: RequestErrorCode, message?: string | null, missing?: readonly MissingSetting[] | null) {
		const sentence = REJECTION_SENTENCES[code] ?? "Rui rejected the request.";
		super(message ?? `${sentence}${missing ? ` Missing: ${missing.join(", ")}.` : ""} [${code}]`);
		this.type = type;
		this.code = code;
		this.missing = missing ?? undefined;
	}
}

/** Rui refused to open. `code` is one of the refusal codes at open (D136). */
export class RuiStartError extends Error {
	override readonly name = "RuiStartError";
	readonly code: StartErrorCode;

	constructor(code: StartErrorCode, message: string) {
		super(message);
		this.code = code;
	}
}

/** The Rui child process is gone, or was never ready. */
export class RuiUnavailableError extends Error {
	override readonly name = "RuiUnavailableError";

	constructor(message: string, options?: { cause?: unknown }) {
		super(message, options);
	}
}

/** The entry contains parts; read an individual part instead. */
export class ContentIsPartsError extends Error {
	override readonly name = "ContentIsPartsError";
	constructor() { super("Content contains parts; use session.readPart(entry, ordinal)"); }
}

/** A wait ended before its condition held. `code` is `wait_timed_out`, the same code the CLI's wait reports. */
export class RuiWaitTimeoutError extends Error {
	override readonly name = "RuiWaitTimeoutError";
	readonly code = "wait_timed_out" as const;

	constructor(message: string) {
		super(message);
	}
}
