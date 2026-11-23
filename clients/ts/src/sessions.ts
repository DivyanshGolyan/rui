import { randomUUID } from "node:crypto";

import type { SessionNotifications } from "./notifications.ts";
import { RuiRequestError, RuiWaitTimeoutError, type RequestAnswer } from "./errors.ts";
import { servedWork, listActivity, searchActivity, type ActivitySearchEntry, type SearchActivityOptions, readContent, readContentBytes, type FeedEntry, type ListActivityOptions } from "./feed.ts";
import { readPartBytes, type ContentValue } from "./parts.ts";
import { WIRE_VERSION, type ReplyLimits } from "./transport.ts";
import type { components } from "./wire.ts";

export interface Link {
	readonly activity?: SessionNotifications;
	exchange(path: string, build: (store: string) => string, environment?: Buffer, limits?: ReplyLimits): Promise<Buffer>;
}

type Schemas = components["schemas"];
export type ActionStatus = Schemas["ReadActionReply"];
export type ActionSelection = Extract<Schemas["ActionBackgroundReply"]["answer"], { status: "accepted" }>["action_selection"];

/** Session settings. The Host resolves omitted creation settings. */
export interface AgentSpec {
	/** The Session Workspace, fixed for its life. Root creation requires it; children inherit it. */
	workspace?: string;
	/** `openai` or `codex`. Fixed for the Session's life. */
	provider?: NonNullable<Schemas["AgentSpec"]["provider"]>;
	/** Creation requires a model, supplied directly or by a preset. May change within the fixed provider. */
	model: string;
	instructions?: string;
	/** JSON output schema object; `null` clears it. */
	outputSchema?: Record<string, unknown> | null;
	/** Configured allowed tool names, such as `bash` and `web_search`. */
	tools?: readonly string[];
	/** Loaded tool intent within `tools`; each Operation freezes its effective model offer. */
	loadedTools?: readonly string[];
	/** Tokens reserved for model output; null clears the override. */
	outputReservation?: number | null;
	permissionMode?: "ask" | "bypass";
	/** Reasoning effort. `null` requests the Host default for the selected model. */
	effort?: Schemas["AgentSpec"]["effort"];
	/** Compact the conversation at this many tokens. `null` requests the Host default. */
	compactAt?: number | null;
	/** Soft creation preferences, used when no stronger setting applies. */
	preferences?: { reasoningEffort?: NonNullable<Schemas["AgentSpec"]["effort"]>; permissionMode?: "ask" | "bypass" };
	/** A name shown in lists. `null` clears it. */
	label?: string | null;
}

/** The same agent spec accepted by creation and connect-time presets. */
export type SessionSpec = AgentSpec;

type CreationSettings = (AgentSpec & { preset?: never }) | (Partial<AgentSpec> & { preset: string });

/** Creation needs a model, directly or from a preset. Roots carry a Workspace; children inherit it. */
export type SessionCreate = CreationSettings & (
	| { workspace: string; parent?: never }
	| { preset: string; parent?: never }
	| {
		/** Create an attached child, inheriting provider, Workspace and Bash environment. */
		parent: string;
		workspace?: never;
		provider?: never;
	}
);

/** The settings `update` may change: everything but the ones fixed at creation. */
export type SessionUpdate = Partial<Pick<SessionSpec, "model" | "instructions" | "outputSchema" | "tools" | "permissionMode" | "effort" | "compactAt" | "label" | "loadedTools" | "outputReservation">>;

export interface WriteOptions {
	/** Optional caller-supplied key for replay. Takes precedence over `idempotencyKey`. */
	key?: string;
	/** Required on `create` and `send`, built as `kind:driftId`. Other writes get a fresh UUIDv4 when it is left out (D123). */
	idempotencyKey?: string;
}

export interface SendOptions {
	idempotencyKey: string;
	/** The environment Bash runs in. Defaults to empty: the caller's own never reaches Bash (D121). */
	env?: Record<string, string>;
}

export type SessionArchiveState = CurrentReport["archive_state"];

export interface ListSessionsOptions {
	/** Defaults to active, including Sessions still settling an archive request. */
	archive?: Schemas["ListSessionsRequest"]["archive"];
}

export interface SessionArchiveResult {
	archived: boolean;
	/** Accepted intent can remain pending until stopped work has really settled. */
	completion: "pending" | "completed";
}

export type SessionPinResult = Pick<Extract<Schemas["SessionPinReply"]["answer"], { status: "accepted" }>, "pinned">;

export interface ServedWork {
	attention: Schemas["SessionWork"]["attention"];
	group: Schemas["SessionWork"]["group"];
	canStop: boolean;
	decide: string | null;
	interruptTarget: InterruptTarget | null;
}

export interface SessionSummary extends ServedWork {
	/** Decimal times and counts remain lossless strings. */
	stateChangeAt: Schemas["SessionRow"]["state_change_at"];
	subtreeStateChangeAt: Schemas["SessionRow"]["subtree_state_change_at"];
	descendantCount: Schemas["SessionRow"]["descendant_count"];
	descendantNeedsYouCount: Schemas["SessionRow"]["descendant_needs_you_count"];
	id: string;
	label: string | null;
	/** The Session's work state, such as `idle`, `working` or `approval`. */
	state: string;
	archiveState: SessionArchiveState;
	parent: string | null;
	/** Session that started this Session, including a detached agent. */
	creator: Schemas["SessionRow"]["creator"];
}

type CurrentReport = Extract<Schemas["InspectSessionReply"], { profile: "current"; work: unknown }>;

/** The observed Turn and Operation IDs as decimal strings. */
export interface InterruptTarget { turn: string; operation: string }

/** Current Host facts. Decimal counts, times and IDs remain lossless strings. */
export interface SessionStatus extends ServedWork {
	archiveState: SessionArchiveState;
	/** `working` includes owed attached-tree work, including unpublished child endings. */
	state: CurrentReport["work"]["state"]["kind"];
	since: CurrentReport["work"]["state"]["since"];
	turn: CurrentReport["work"]["turn"];
	operation: CurrentReport["work"]["operation"];
	/** The Host-served target for interrupting the observed model call. */
	interruptTarget: InterruptTarget | null;
	pendingMessages: CurrentReport["pending_messages"];
	parent: CurrentReport["session"]["parent"];
	label: CurrentReport["session"]["label"];
	model: CurrentReport["session"]["model"];
	effort: CurrentReport["session"]["reasoning_effort"];
	/** Configured allowed tool names. */
	tools: CurrentReport["session"]["tools"];
	/** Loaded tool intent; an active Operation keeps its frozen model offer. */
	loadedTools: CurrentReport["session"]["loaded_tools"];
	permissionMode: CurrentReport["session"]["permission_mode"];
	latestOutcome: CurrentReport["work"]["latest_outcome"];
}

export interface ModelSummary {
	provider: string;
	id: string;
	known: boolean;
}

export function agentSpec(spec: Partial<SessionSpec>): Schemas["Configuration"] {
	return {
		...(spec.workspace === undefined ? {} : { workspace: spec.workspace }),
		...(spec.provider === undefined ? {} : { provider: spec.provider }),
		...(spec.model === undefined ? {} : { model: spec.model }),
		...(spec.instructions === undefined ? {} : { instructions: spec.instructions }),
		...(spec.tools === undefined ? {} : { tools: [...new Set(spec.tools)].sort() }),
		...(spec.loadedTools === undefined ? {} : { loadedTools: [...new Set(spec.loadedTools)].sort() }),
		...(spec.permissionMode === undefined ? {} : { permissionMode: spec.permissionMode }),
		...(spec.outputSchema === undefined ? {} : { outputSchema: spec.outputSchema }),
		...(spec.compactAt === undefined ? {} : { compactAt: spec.compactAt }),
		...(spec.outputReservation === undefined ? {} : { outputReservation: spec.outputReservation }),
		...(spec.effort === undefined ? {} : { effort: spec.effort }),
		...(spec.label === undefined ? {} : { label: spec.label }),
		...(spec.preferences === undefined ? {} : { preferences: {
			...(spec.preferences.reasoningEffort === undefined ? {} : { reasoning_effort: spec.preferences.reasoningEffort }),
			...(spec.preferences.permissionMode === undefined ? {} : { permission_mode: spec.preferences.permissionMode }),
		} }),
	};
}

function configureBody(store: string, key: string, session: string, spec: Partial<AgentSpec> & { preset?: string; parent?: string }): string {
	return JSON.stringify({
		version: WIRE_VERSION,
		kind: "configure",
		store,
		key,
		session,
		configuration: { ...agentSpec(spec), ...(spec.parent === undefined ? {} : { parent: spec.parent }) },
		...(spec.preset === undefined ? {} : { preset: spec.preset }),
	} satisfies Schemas["ConfigureRequest"]);
}

function key(options: WriteOptions | undefined): string {
	return options?.key ?? options?.idempotencyKey ?? randomUUID();
}

function parse<T>(reply: Buffer): T {
	return JSON.parse(reply.toString("utf8")) as T;
}

function accepted<A extends RequestAnswer>(answer: A): Extract<A, { status: "accepted" }> {
	if (answer.status !== "accepted")
		throw new RuiRequestError(answer.status, answer.code, "message" in answer ? answer.message : undefined, "missing" in answer ? answer.missing : undefined);
	return answer as Extract<A, { status: "accepted" }>;
}

export function environmentBytes(env: Record<string, string> | undefined): Buffer {
	const forwarded = Object.entries(env ?? {}).filter(
		([name, entry]) => name !== "" && !name.startsWith("RUI_") && !/[=\0]/.test(name) && !entry.includes("\0"),
	);
	return Buffer.from(forwarded.map(([name, entry]) => `${name}=${entry}\0`).join(""), "utf8");
}

export class Session {
	readonly #link: Link;
	#interruptTarget: InterruptTarget | null = null;
	readonly id: string;

	constructor(link: Link, id: string) {
		this.#link = link;
		this.id = id;
	}

	/**
	 * The Session's feed, in order, as an async iterator (D9). Without `follow`
	 * it ends at the current end. With it, busy Sessions poll with backoff; idle Sessions
	 * wait for a local write on this Rui instance (not writes from another process).
	 * See `ListActivityOptions.follow`; `signal` abort also ends an idle wait.
	 */
	listActivity(options?: ListActivityOptions): AsyncGenerator<FeedEntry, void, undefined> {
		return listActivity(this.#link, this.id, options, (target) => { this.#interruptTarget = target; });
	}

	/** Search public feed text newest first, with bounded snippets. */
	searchActivity(query: string, options?: SearchActivityOptions): AsyncGenerator<ActivitySearchEntry, void, undefined> {
		return searchActivity(this.#link, this.id, query, options);
	}

	/** The whole text of an entry (D134). Past about 512 MiB a string cannot hold it and this throws: use `readContentBytes`. */
	readContent(entry: Pick<FeedEntry, "position" | "ordinal">): Promise<string> {
		return readContent(this.#link, this.id, entry);
	}

	/** The whole text of an entry as UTF-8 bytes, up to the Host's limit of about 1 GiB. */
	readContentBytes(entry: Pick<FeedEntry, "position" | "ordinal">): Promise<Buffer> {
		return readContentBytes(this.#link, this.id, entry);
	}

	/** The exact bytes of one part of a parts entry; rejects with `TypeError` for an entry whose content is not parts. */
	async readPart(entry: { content: ContentValue | null }, ordinal: number): Promise<Buffer> {
		if (entry.content?.type !== "parts") throw new TypeError("entry content is not parts");
		return readPartBytes(this.#link, this.id, entry.content.owner, ordinal);
	}

	/** A Current report's summary (D12). A separate ending is not reported. */
	async status(): Promise<SessionStatus> {
		const reply = parse<Extract<Schemas["InspectSessionReply"], { profile: "current" }>>(
			await this.#link.exchange("/v1/inspect-session", (store) => JSON.stringify({
				version: WIRE_VERSION,
				kind: "inspect_session",
				store,
				session: this.id,
			} satisfies Schemas["InspectSessionRequest"])),
		);
		if (reply.session === null) throw new RuiRequestError("invocation_error", "session_not_found");
		const served = servedWork(reply.work);
		this.#interruptTarget = served.interruptTarget === null ? null : { ...served.interruptTarget };
		return {
			archiveState: reply.archive_state,
			state: reply.work.state.kind,
			since: reply.work.state.since,
			turn: reply.work.turn,
			operation: reply.work.operation,
			...served,
			pendingMessages: reply.pending_messages,
			parent: reply.session.parent,
			label: reply.session.label,
			model: reply.session.model,
			effort: reply.session.reasoning_effort,
			tools: reply.session.tools,
			loadedTools: reply.session.loaded_tools,
			permissionMode: reply.session.permission_mode,
			latestOutcome: reply.work.latest_outcome,
		};
	}

	/** Sends a Message. The receipt is its admission number; the answer arrives in the feed (D8). */
	async send(text: string, options: SendOptions): Promise<{ messageId: string }> {
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "message",
				store,
				key: options.idempotencyKey,
				session: this.id,
				sender: null,
				sender_handle: null,
				text: { state: "value", value: text },
			} satisfies Schemas["MessageRequest"]);
		const reply = parse<Schemas["MessageReply"]>(await this.#link.exchange("/v1/message", body, environmentBytes(options.env)));
		const messageId = accepted(reply.answer).admission;
		this.#link.activity?.notify(this.id);
		return { messageId };
	}

	/** Changes settings. Omitted fields stay as they are. Resolves once the Host accepted the change (D7). */
	async update(fields: SessionUpdate, options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["ConfigureReply"]>(
			await this.#link.exchange("/v1/configure", (store) => configureBody(store, idempotencyKey, this.id, fields)),
		);
		accepted(reply.answer);
		this.#link.activity?.notify(this.id);
	}

	/** Stops the current and queued work. The Session stays usable (D14). */
	async stop(options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "session_stop",
				store,
				key: idempotencyKey,
				session: this.id,
			} satisfies Schemas["SessionStopRequest"]);
		accepted(parse<Schemas["SessionStopReply"]>(await this.#link.exchange("/v1/control/session-stop", body)).answer);
		this.#link.activity?.notify(this.id);
	}

	/** Stops work and archives after real settlement, using one durable intent. */
	archive(options?: WriteOptions): Promise<SessionArchiveResult> {
		return this.#setArchived(true, options);
	}

	/** Restores organization only. Previously stopped work is never resumed. */
	unarchive(options?: WriteOptions): Promise<SessionArchiveResult> {
		return this.#setArchived(false, options);
	}

	async #setArchived(archived: boolean, options?: WriteOptions): Promise<SessionArchiveResult> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["SessionArchiveReply"]>(await this.#link.exchange(
			"/v1/control/session-archive",
			(store) => JSON.stringify({
				version: WIRE_VERSION,
				kind: "session_archive",
				store,
				key: idempotencyKey,
				session: this.id,
				archived,
			} satisfies Schemas["SessionArchiveRequest"]),
		));
		const answer = accepted(reply.answer);
		const completion = reply.completion.status;
		if (completion === "unavailable") throw new RuiRequestError("invocation_error", "invalid_response");
		this.#link.activity?.notify(this.id);
		return { archived: answer.archived, completion };
	}

	/** Pins this Session without starting or interrupting work. Repeated pins preserve its position. */
	pin(options?: WriteOptions): Promise<SessionPinResult> {
		return this.#setPinned(true, options);
	}

	/** Removes this Session's pin without changing its work. */
	unpin(options?: WriteOptions): Promise<SessionPinResult> {
		return this.#setPinned(false, options);
	}

	async #setPinned(pinned: boolean, options?: WriteOptions): Promise<SessionPinResult> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["SessionPinReply"]>(await this.#link.exchange(
			"/v1/control/session-pin",
			(store) => JSON.stringify({
				version: WIRE_VERSION,
				kind: "session_pin",
				store,
				key: idempotencyKey,
				session: this.id,
				pinned,
			} satisfies Schemas["SessionPinRequest"]),
		));
		const answer = accepted(reply.answer);
		this.#link.activity?.notify(this.id);
		return { pinned: answer.pinned };
	}

	/** Releases the original call with an immutable receipt. Poll `readAction` for the sole final result. */
	async backgroundAction(action: string, options?: WriteOptions): Promise<ActionSelection> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["ActionBackgroundReply"]>(await this.#link.exchange(
			"/v1/control/action-background",
			(store) => JSON.stringify({
				version: WIRE_VERSION, kind: "action_background", store,
				key: idempotencyKey, session: this.id, action,
			} satisfies Schemas["ActionBackgroundRequest"]),
		));
		const answer = accepted(reply.answer);
		this.#link.activity?.notify(this.id);
		return answer.action_selection;
	}

	/** Selects an owned Action for stop. Reuse the key to recover a lost reply. */
	async stopAction(action: string, options?: WriteOptions): Promise<string | null> {
		const idempotencyKey = key(options);
		const reply = parse<Schemas["ActionStopReply"]>(await this.#link.exchange(
			"/v1/control/action-stop",
			(store) => JSON.stringify({
				version: WIRE_VERSION, kind: "action_stop", store,
				key: idempotencyKey, session: this.id, action,
			} satisfies Schemas["ActionStopRequest"]),
		));
		const answer = accepted(reply.answer);
		this.#link.activity?.notify(this.id);
		return answer.resolution_position;
	}

	/** Reads an owned Action. Acceptance and attempted state do not assert a running process. */
	async readAction(action: string, offset = "0", after = "0"): Promise<ActionStatus> {
		return parse<ActionStatus>(await this.#link.exchange("/v1/read-action", (store) => JSON.stringify({
			version: WIRE_VERSION, kind: "read_action", store, session: this.id, action, offset, after,
		} satisfies Schemas["ReadActionRequest"])));
	}

	/** Interrupt an observed target with one keyed request. Reuse the key to replay its answer.
	 * `operation_resolved` and `target_mismatch` resolve without effect. With no target, use this handle's
	 * last status or feed observation; send nothing when it had no interrupt target.
	 * Neither form reads first.
	 */
	interrupt(target: InterruptTarget, options?: WriteOptions): Promise<void>;
	interrupt(options?: WriteOptions): Promise<void>;
	async interrupt(targetOrOptions?: InterruptTarget | WriteOptions, options?: WriteOptions): Promise<void> {
		const explicit = targetOrOptions !== undefined && "turn" in targetOrOptions;
		const target = explicit ? targetOrOptions : this.#interruptTarget;
		if (target === null) return;
		const { turn, operation } = target;
		const idempotencyKey = key(explicit ? options : targetOrOptions);
		const body = (store: string) => JSON.stringify({
			version: WIRE_VERSION, kind: "model_interruption", store,
			key: idempotencyKey, target: { session: this.id, turn, operation },
		} satisfies Schemas["ModelInterruptionRequest"]);
		try {
			accepted(parse<Schemas["ModelInterruptionReply"]>(await this.#link.exchange("/v1/control/model-interruption", body)).answer);
		} catch (error) {
			const gone = error instanceof RuiRequestError && (error.code === "operation_resolved" || error.code === "target_mismatch");
			if (!gone) throw error;
		}
		this.#link.activity?.notify(this.id);
	}

	/** Answers an approval. `requestId` is the Action id of the `approval_requested` entry (D15). */
	async decide(requestId: string, decision: "allow" | "deny", options?: WriteOptions): Promise<void> {
		const idempotencyKey = key(options);
		const wire = decision === "allow" ? "allow_once" : "deny";
		const body = (store: string) =>
			JSON.stringify({
				version: WIRE_VERSION,
				kind: "permission_decision",
				store,
				key: idempotencyKey,
				session: this.id,
				action: requestId,
				decision: wire,
			} satisfies Schemas["PermissionDecisionRequest"]);
		accepted(parse<Schemas["PermissionDecisionReply"]>(await this.#link.exchange("/v1/control/permission-decision", body)).answer);
		this.#link.activity?.notify(this.id);
	}
}

export class Sessions {
	readonly #link: Link;

	constructor(link: Link) {
		this.#link = link;
	}

	/** Creates a Session. The key is required: a repeat returns the same Session (D7, D17). */
	async create(spec: SessionCreate, options: { idempotencyKey: string }): Promise<Session> {
		const reply = parse<Schemas["ConfigureReply"]>(
			await this.#link.exchange("/v1/configure", (store) => configureBody(store, options.idempotencyKey, "", spec)),
		);
		return new Session(this.#link, accepted(reply.answer).session);
	}

	/** Configured Sessions, newest first; archived Sessions are hidden by default. */
	async list(options?: ListSessionsOptions): Promise<SessionSummary[]> {
		const summaries: SessionSummary[] = [];
		let after = "0";
		let ceiling = "0";
		for (;;) {
			const wireAfter = after;
			const wireCeiling = ceiling;
			// The live roster: the Archived window reply (the one with `next.more_above`) is read by its own client.
			const page = parse<Exclude<Schemas["ListSessionsReply"], { next: { more_above: boolean } }>>(
				await this.#link.exchange(
					"/v1/list-sessions",
					(store) => JSON.stringify({
						version: WIRE_VERSION,
						kind: "list_sessions",
						store,
						workspace: null,
						archive: options?.archive ?? "active",
						after: wireAfter,
						ceiling: wireCeiling,
					} satisfies Schemas["ListSessionsRequest"]),
				),
			);
			for (const row of page.sessions) {
				summaries.push({
					id: row.reference, label: row.label, state: row.work.state.kind, ...servedWork(row.work), archiveState: row.archive_state, parent: row.parent, creator: row.creator,
					stateChangeAt: row.state_change_at, subtreeStateChangeAt: row.subtree_state_change_at,
					descendantCount: row.descendant_count, descendantNeedsYouCount: row.descendant_needs_you_count,
				});
			}
			if (page.next === null || !("after" in page.next)) return summaries.reverse();
			after = page.next.after;
			ceiling = page.next.ceiling;
		}
	}
}

export async function models(link: Link): Promise<ModelSummary[]> {
	const reply = parse<Schemas["ModelListReply"]>(
		await link.exchange("/v1/model-list", (store) => JSON.stringify({
			version: WIRE_VERSION,
			kind: "model_list",
			store,
		} satisfies Schemas["ModelListRequest"])),
	);
	return reply.providers.flatMap((entry) => entry.models.map((model) => ({ provider: entry.provider, id: model.id, known: model.known })));
}

export async function setPaused(link: Link, paused: boolean): Promise<void> {
	await link.exchange("/v1/control/host-pause", (store) => JSON.stringify({
		version: WIRE_VERSION,
		kind: "host_pause",
		store,
		paused,
	} satisfies Schemas["HostPauseRequest"]));
}

const RELOAD_POLL_MS = 250;
const RELOAD_WAIT_MS = 60_000;

export interface ToolReloadOutcome {
	server: string;
	outcome: "never" | "listed" | "failed" | "collision";
	tools: number;
}

/**
 * Asks the Host to list one MCP server, or every configured server, again, then polls `tools_status` until each asked
 * generation has landed. Rejects with RuiWaitTimeoutError after 60 s.
 */
export async function reloadTools(link: Link, server?: string): Promise<ToolReloadOutcome[]> {
	const asked = parse<Schemas["ToolsReloadReply"]>(
		await link.exchange("/v1/control/tools-reload", (store) => JSON.stringify({
			version: WIRE_VERSION,
			kind: "tools_reload",
			store,
			...(server === undefined ? {} : { server }),
		} satisfies Schemas["ToolsReloadRequest"])),
	).asked;
	const deadline = Date.now() + RELOAD_WAIT_MS;
	for (;;) {
		const status = parse<Schemas["ToolsStatusReply"]>(
			await link.exchange("/v1/tools-status", (store) => JSON.stringify({
				version: WIRE_VERSION,
				kind: "tools_status",
				store,
			} satisfies Schemas["ToolsStatusRequest"])),
		).servers;
		const rows = asked.map((ask) => {
			const row = status.find((entry) => entry.server === ask.server);
			return { ask, row };
		});
		const landed = rows.every(({ ask, row }) => row !== undefined && BigInt(row.finished) >= BigInt(ask.generation));
		if (landed) {
			return rows.map(({ ask, row }) => ({ server: ask.server, outcome: row!.last, tools: Number(row!.tools) }));
		}
		const remaining = deadline - Date.now();
		if (remaining <= 0) {
			const pending = rows.filter(({ ask, row }) => row === undefined || BigInt(row.finished) < BigInt(ask.generation)).map(({ ask }) => ask.server);
			throw new RuiWaitTimeoutError(`MCP tool lists still pending after 60 seconds: ${pending.join(", ")}`);
		}
		await new Promise((resolve) => setTimeout(resolve, Math.min(RELOAD_POLL_MS, remaining)));
	}
}
