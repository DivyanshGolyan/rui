import { request } from "node:http";
import type { Socket } from "node:net";

import { ConnectionError, refusal, WIRE_VERSION } from "./transport.ts";

/** A frame the Host sends on the held line. A nudge names a Session and carries no saved fact. */
export type LineFrame =
	| { type: "hello"; line: number; instance: string }
	| { type: "changed"; session: string }
	| { type: "resync" }
	| { type: "failed"; code: string }
	| { type: "ping" };

const MAX_FRAME_BYTES = 16 * 1024;

/** The Host sent a frame outside the line's grammar: a length of 0 or above 16 KiB, or a payload that is no known frame. */
export class LineProtocolError extends Error {
	override readonly name = "LineProtocolError";
}

export interface LineHandler {
	frame(frame: LineFrame): void;
	/** Called once per line. `error` is set when the line ended by a socket error or a malformed frame. */
	closed(line: Line, error: Error | undefined): void;
}

/**
 * One held, notification-only connection to a Host (`GET /v1/line`, docs/contracts/inspection.md#live-line). The client
 * sends `watch` frames and reads nudges. It holds no Session state; `Follows` decides what a nudge means.
 */
export class Line {
	readonly #socket: Socket;
	readonly #handler: LineHandler;
	#pending: Buffer = Buffer.alloc(0);
	#ended = false;

	private constructor(socket: Socket, handler: LineHandler) {
		this.#socket = socket;
		this.#handler = handler;
	}

	/** Upgrades to a line on the Host's socket. Resolves once the Host has switched protocols; a refusal rejects with its error. */
	static open(options: { socketPath: string; instance: string; handler: LineHandler }): Promise<Line> {
		return new Promise((resolve, reject) => {
			const outgoing = request({
				socketPath: options.socketPath,
				path: "/v1/line",
				method: "GET",
				agent: false,
				headers: {
					Connection: "Upgrade",
					Upgrade: "rui-line/1",
					"X-Rui-Wire-Version": WIRE_VERSION,
					"X-Rui-Host-Instance": options.instance,
				},
			});
			outgoing.on("error", (error) => reject(new ConnectionError(error.message, { cause: error })));
			outgoing.on("response", (incoming) => {
				const chunks: Buffer[] = [];
				incoming.on("data", (chunk: Buffer) => chunks.push(chunk));
				incoming.on("error", (error) => reject(new ConnectionError(error.message, { cause: error })));
				incoming.on("end", () => reject(refusal(incoming.statusCode, Buffer.concat(chunks))));
			});
			outgoing.on("upgrade", (_incoming, socket, head) => {
				// Held while a watcher follows: a following script stays alive until its watch ends, and the line closes with the last one.
				const line = new Line(socket, options.handler);
				socket.on("data", (chunk: Buffer) => line.#receive(chunk));
				socket.on("error", (error) => line.#finish(new ConnectionError(error.message, { cause: error })));
				socket.on("close", () => line.#finish(undefined));
				resolve(line);
				if (head.length > 0) line.#receive(head);
			});
			outgoing.end();
		});
	}

	/** False once the line has ended, by either side. */
	get isOpen(): boolean {
		return !this.#ended;
	}

	/** Replaces the watched set with `sessions`. The Host nudges each listed Session once. */
	watch(sessions: readonly string[]): void {
		this.#send({ type: "watch", sessions: [...sessions] });
	}

	/** Closes the socket. The handler's `closed` runs once, with no error. */
	close(): void {
		this.#finish(undefined);
	}

	#send(payload: object): void {
		if (this.#ended) return;
		const json = Buffer.from(JSON.stringify(payload));
		const frame = Buffer.alloc(4 + json.length);
		frame.writeUInt32BE(json.length, 0);
		json.copy(frame, 4);
		this.#socket.write(frame);
	}

	#receive(chunk: Buffer): void {
		this.#pending = this.#pending.length === 0 ? chunk : Buffer.concat([this.#pending, chunk]);
		while (!this.#ended && this.#pending.length >= 4) {
			const length = this.#pending.readUInt32BE(0);
			if (length === 0 || length > MAX_FRAME_BYTES) {
				this.#finish(new LineProtocolError(`the line sent a frame of ${length} bytes`));
				return;
			}
			if (this.#pending.length < 4 + length) return;
			const payload = this.#pending.subarray(4, 4 + length).toString("utf8");
			this.#pending = this.#pending.subarray(4 + length);
			let frame: LineFrame;
			try {
				frame = parseFrame(payload);
			} catch (error) {
				this.#finish(new LineProtocolError("the line sent a frame it does not know", { cause: error }));
				return;
			}
			this.#handler.frame(frame);
		}
	}

	#finish(error: Error | undefined): void {
		if (this.#ended) return;
		this.#ended = true;
		this.#pending = Buffer.alloc(0);
		this.#socket.destroy();
		this.#handler.closed(this, error);
	}
}

function parseFrame(text: string): LineFrame {
	const value: unknown = JSON.parse(text);
	if (typeof value !== "object" || value === null || !("type" in value)) throw new TypeError("not a frame");
	switch (value.type) {
		case "hello":
			if ("line" in value && typeof value.line === "number" && "instance" in value && typeof value.instance === "string") {
				return { type: "hello", line: value.line, instance: value.instance };
			}
			break;
		case "changed":
			if ("session" in value && typeof value.session === "string") return { type: "changed", session: value.session };
			break;
		case "resync":
		case "ping":
			return { type: value.type };
		case "failed":
			if ("code" in value && typeof value.code === "string") return { type: "failed", code: value.code };
			break;
	}
	throw new TypeError(`unknown frame ${String(value.type)}`);
}
