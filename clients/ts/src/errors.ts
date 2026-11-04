// The three error types a caller sees (D116). Request failures are
// RuiRequestError, a refusal at open is RuiStartError, and a call that finds
// no running Host is RuiUnavailableError.

/** Rui rejected one request. `code` is the Host's rejection code. */
export class RuiRequestError extends Error {
	override readonly name = "RuiRequestError";
	readonly code: string;
	/** The Host's error class, such as `invocation_error` or `busy`. */
	readonly type: string;

	constructor(type: string, code: string) {
		super(`Rui rejected the request: ${code}`);
		this.type = type;
		this.code = code;
	}
}

/** Rui refused to open. `code` is one of the refusal codes at open (D136). */
export class RuiStartError extends Error {
	override readonly name = "RuiStartError";
	readonly code: string;

	constructor(code: string, message: string) {
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
