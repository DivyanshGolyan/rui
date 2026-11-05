// The three error types a caller sees (D116). Request failures are
// RuiRequestError, a refusal at open is RuiStartError, and a call that finds
// no running Host is RuiUnavailableError.

import type { components } from "./wire.ts";

type Schemas = components["schemas"];
type Reply = Schemas[Extract<keyof Schemas, `${string}Reply`>];
type Answer<T> = T extends { answer: infer A } ? A : never;
type Code<T> = T extends { code: infer C extends string } ? C : never;
type Status<T> = T extends { status: infer S extends string } ? S : never;

export type RequestAnswer = Answer<Reply>;
export type RequestRejectionCode = Code<RequestAnswer>;
/** HTTP ErrorReply deliberately accepts codes beyond the command rejection enums. */
export type RequestErrorCode = RequestRejectionCode | Schemas["ErrorReply"]["code"];
type RequestErrorType = Schemas["ErrorReply"]["type"] | Status<Extract<RequestAnswer, { code: string }>>;
type StartErrorCode = Schemas["StartError"]["rui_start_error"]["code"];

/** Rui rejected one request. `code` is the Host's rejection code. */
export class RuiRequestError extends Error {
	override readonly name = "RuiRequestError";
	readonly code: RequestErrorCode;
	/** The Host's error class, such as `invocation_error` or `busy`. */
	readonly type: RequestErrorType;

	constructor(type: RequestErrorType, code: RequestErrorCode) {
		super(`Rui rejected the request: ${code}`);
		this.type = type;
		this.code = code;
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
