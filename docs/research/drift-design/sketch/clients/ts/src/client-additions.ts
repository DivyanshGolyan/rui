// Changes to clients/ts/src/client.ts, errors.ts and sessions.ts (sketch).
// Imports name the repo's existing modules.

import type { HostSettings } from "./settings.ts";
import type { AppTool, Tools } from "./tools.ts";
import type { WatchEvent, WatchOptions } from "./watch.ts";

// ---------------------------------------------------------------- errors.ts (U1)

/**
 * The Host's Store failed, so nothing more runs or commits until the Host is restarted
 * after repair; restart recovers from what was committed. Every pending and later call on
 * the same `Rui` rejects with this one error, whichever path noticed first:
 *   a reply `canonical_store_failure`, `host-info` `dispatch_fenced`,
 *   the line's `failed {code: "store_failed"}`, or the Host's `store_fenced` stdout line.
 * Do not resubmit work whose outcome you did not see: resend it under the same key.
 */
export class RuiStoreFailedError extends Error {
	override readonly name = "RuiStoreFailedError";
	constructor(options?: { cause?: unknown }) {
		super("The Rui Store failed; restart the Host after repair.", options);
	}
}

// ---------------------------------------------------------------- client.ts

export interface RuiAdditions {
	/** U3: the line, opened at connect and attach. Private: no public surface. */
	// #line: Line

	/** U7: serve app tools from this process. */
	readonly tools: Tools;

	/**
	 * U1: the one failure owner. Maps every store-failure cause to RuiStoreFailedError,
	 * rejects every pending exchange, watch and claim, and makes later calls reject.
	 * The client keeps reading the Host's stdout after readiness so `store_fenced` lands here.
	 */
	// #fail(cause: unknown): void
}

export interface RuiStatics {
	/** Starts Rui as a child of this process (today's connect). */
	connect(settings: HostSettings): Promise<unknown>;
	/**
	 * U2: attach to a detached Host by its saved Host directory (`rui host start --store DIR`).
	 * Several processes attach to one Host; none of them owns its lifetime. Refuses with
	 * RuiUnavailableError when no Host answers there.
	 */
	attach(hostDir: string): Promise<unknown>;
}

// ---------------------------------------------------------------- sessions.ts

export interface AgentSpecAdditions {
	/**
	 * U6: the app tools this Session declares, the whole set. Omitted keeps it; [] clears it.
	 * Helpers started by the model get the ones their `tools` names, or all of them when it
	 * names none of them; their calls are served by whoever serves this Session's lane.
	 */
	appTools?: readonly AppTool[];
}

export interface SessionAdditions {
	/** U4: follow the Session. Replaces `listActivity({ follow: true })`. */
	watch(options?: WatchOptions): AsyncGenerator<WatchEvent, void, undefined>;

	/**
	 * U5: start a new context, keeping the history. Queued like a Message; placed when the
	 * next Turn binds input, so a running Turn finishes first. Starts no Turn by itself.
	 */
	reset(options: { handoff?: string; idempotencyKey: string }): Promise<{ admission: string }>;
}

/** U10/U11: `rui.import(transcript)` lives in transcript.ts. */
export type {};
