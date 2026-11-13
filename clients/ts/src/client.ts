// Rui.connect starts the Host as a child of this process, hands it the settings
// document on stdin and waits until it answers host-info on the socket in its
// private interface (D107, D112, D130, D131). By default the child lives as
// long as stdin stays open (D5, D118); settings may select detached lifetime.
// A child that exits on its own is restarted with
// capped backoff, and calls in flight are retried once the new Host is ready;
// every write carries a request key, so a retry is safe (D118, D129).
import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtemp, rm, stat, symlink } from "node:fs/promises";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { pipeSettings, type HostSettings } from "./settings.ts";
import { SessionNotifications } from "./notifications.ts";
import { resolveBinary } from "./binary.ts";
import { RuiStartError, RuiUnavailableError } from "./errors.ts";
import { agentSpec, models, Session, Sessions, setPaused, type AgentSpec, type ModelSummary } from "./sessions.ts";
import { ConnectionError, post, WIRE_VERSION, type ReplyLimits } from "./transport.ts";
import type { components } from "./wire.ts";

type Schemas = components["schemas"];

export type { HostSettings } from "./settings.ts";

/** Options belonging to the client, not the Host settings document. */
export interface ClientOptions {
	/** How long connect retries another Host's Store lock. Default 120 000 ms. */
	lockWaitMs?: number;
	/** Default: the installed platform package's executable, else rui on PATH. */
	binary?: string;
}

/** Fires on every child exit, including one the client restarts from (D129). */
export interface ExitEvent {
	code: number | null;
	signal: NodeJS.Signals | null;
	restarting: boolean;
}

type HostInfo = components["schemas"]["HostInfoReply"];

const SOCKET_NAME = "rui.sock";
const DEFAULT_LOCK_WAIT_MS = 120_000;
const LOCK_RETRY_MS = 500;
const FIRST_RESTART_MS = 500;
const MAX_RESTART_MS = 30_000;
/** The Host bounds its own shutdown at 10 s (D118); this leaves room for the exit to arrive. */
const CLOSE_GRACE_MS = 15_000;
const READY_POLL_MS = 25;
const READINESS_RECEIPT_BYTES = Buffer.byteLength("ready instance=") + 32 + 1;
/** How long a refused connection waits for the child's exit before it counts as unanswered. */
const EXIT_NOTICE_MS = 2_000;
/** Transient refusals during automatic restart, not initial connect. */
const RETRYABLE_START_CODES = new Set<RuiStartError["code"]>(["store_locked", "mysql_unreachable"]);

interface Exit {
	code: number | null;
	signal: NodeJS.Signals | null;
}

/** A child that answered host-info. */
interface Host {
	child: ChildProcess;
	instance: string;
	info: HostInfo;
	exited: Promise<Exit>;
}

interface Waiter {
	resolve: (host: Host) => void;
	reject: (error: Error) => void;
}

interface Launch {
	binary: string;
	document: Buffer;
	interfaceDir: NonNullable<NonNullable<Schemas["HostSettings"]["interface"]>["dir"]>;
	aliasReady?: Promise<void>;
	detached: boolean;
	socketPath: string;
	env: NodeJS.ProcessEnv;
}

/** A failed start, with the child's exit when there was a child. */
class AttemptFailed extends Error {
	readonly error: Error;
	readonly exit: Exit | undefined;

	constructor(error: Error, exit: Exit | undefined) {
		super(error.message);
		this.error = error;
		this.exit = exit;
	}
}

export class Rui extends EventEmitter<{ exit: [ExitEvent] }> {
	readonly #launch: Launch;
	readonly #runtimeDir: string;
	#host: Host | undefined;
	/** The child of the latest start, ready or not. */
	#child: ChildProcess | undefined;
	#waiters: Waiter[] = [];
	#backoff = FIRST_RESTART_MS;
	#restart: NodeJS.Timeout | undefined;
	#closing: Promise<void> | undefined;
	#dead: Error | undefined;
	/** Local Session write notifications, shared by every handle. Internal. */
	readonly activity = new SessionNotifications();
	/** Create and list Sessions. */
	readonly sessions: Sessions = new Sessions(this);

	private constructor(launch: Launch, runtimeDir: string, host: Host) {
		super();
		this.#launch = launch;
		this.#runtimeDir = runtimeDir;
		this.#adopt(host);
	}

	/** Starts Rui as a child of this process and resolves once it is ready. */
	static async connect(settings: HostSettings, options: ClientOptions = {}): Promise<Rui> {
		const runtimeDir = await mkdtemp(join(tmpdir(), "rui-"));
		let launch: Launch | undefined;
		try {
			launch = launchFor(settings, runtimeDir, options);
			const deadline = Date.now() + (options.lockWaitMs ?? DEFAULT_LOCK_WAIT_MS);
			for (;;) {
				try {
					return new Rui(launch, runtimeDir, await start(launch, () => {}));
				} catch (failure) {
					const error = failure instanceof AttemptFailed ? failure.error : (failure as Error);
					const remaining = deadline - Date.now();
					if (!(error instanceof RuiStartError && error.code === "store_locked") || remaining <= 0) throw error;
					await sleep(Math.min(LOCK_RETRY_MS, remaining));
				}
			}
		} catch (error) {
			if (launch) disposeLaunch(launch);
			await rm(runtimeDir, { recursive: true, force: true });
			throw error;
		}
	}

	/** A handle on an existing Session. Does no I/O: an unknown id fails on the first call (D16). */
	getSession(id: string): Session {
		return new Session(this, id);
	}

	/** The models each provider offers. */
	models(): Promise<ModelSummary[]> {
		return models(this);
	}

	/** Holds every new Turn until `resume`. Running work continues. */
	pause(): Promise<void> {
		return setPaused(this, true);
	}

	resume(): Promise<void> {
		return setPaused(this, false);
	}

	/**
	 * Closes the child's stdin and resolves once it has exited, bounded by the
	 * Host's 10 s shutdown (D129). Later calls fail with RuiUnavailableError.
	 */
	close(): Promise<void> {
		this.#closing ??= this.#close();
		return this.#closing;
	}

	async #close(): Promise<void> {
		clearTimeout(this.#restart);
		this.#fail(new RuiUnavailableError("the Rui client is closed"));
		const child = this.#child;
		this.#host = undefined;
		try {
			if (child && child.exitCode === null && child.signalCode === null) {
				const exited = exitOf(child);
				child.stdin?.end();
				if (this.#launch.detached) child.kill("SIGTERM");
				const timer = setTimeout(() => child.kill("SIGKILL"), CLOSE_GRACE_MS);
				const exit = await exited;
				clearTimeout(timer);
				this.emit("exit", { ...exit, restarting: false });
			}
		} finally {
			disposeLaunch(this.#launch);
			await rm(this.#runtimeDir, { recursive: true, force: true });
		}
	}

	/**
	 * Sends one request to the ready Host. A call that finds the child gone
	 * waits for the restarted Host and is sent once more. Internal: the
	 * package's calls are built on it.
	 */
	async call(path: string, body: string, environment?: Buffer, limits?: ReplyLimits): Promise<Buffer> {
		let retried = false;
		for (;;) {
			const host = await this.#ready();
			try {
				return await post({
					socketPath: this.#launch.socketPath,
					path,
					body,
					instance: host.instance,
					...(environment ? { environment } : {}),
					...(limits ? { limits } : {}),
				});
			} catch (error) {
				if (!(error instanceof ConnectionError)) throw error;
				const gone = await Promise.race([host.exited.then(() => true), sleep(EXIT_NOTICE_MS, false)]);
				if (!gone || retried) throw new RuiUnavailableError("the Rui Host did not answer", { cause: error });
				retried = true;
			}
		}
	}

	/**
	 * Sends one request built for the Host's Store. `build` receives the
	 * canonical Store name the Host reported at readiness. Internal: the
	 * package's calls are built on it.
	 */
	async exchange(path: string, build: (store: string) => string, environment?: Buffer, limits?: ReplyLimits): Promise<Buffer> {
		const host = await this.#ready();
		return this.call(path, build(host.info.store), environment, limits);
	}

	/** The running child's process id. Internal. */
	get pid(): number | undefined {
		return this.#host?.child.pid;
	}

	/** The latest host-info reply. Internal. */
	get hostInfo(): HostInfo | undefined {
		return this.#host?.info;
	}

	#ready(): Promise<Host> {
		if (this.#host) return Promise.resolve(this.#host);
		const failed = this.#dead ?? (this.#closing ? new RuiUnavailableError("the Rui client is closed") : undefined);
		if (failed) return Promise.reject(failed);
		this.#restart?.ref();
		return new Promise((resolve, reject) => this.#waiters.push({ resolve, reject }));
	}

	#adopt(host: Host): void {
		this.#host = host;
		this.#child = host.child;
		this.#backoff = FIRST_RESTART_MS;
		for (const waiter of this.#waiters.splice(0)) waiter.resolve(host);
		void host.exited.then((exit) => {
			if (this.#closing || this.#host !== host) return;
			this.#host = undefined;
			this.emit("exit", { ...exit, restarting: true });
			this.#scheduleRestart();
		});
	}

	#fail(error: Error): void {
		this.activity.fail(error);
		for (const waiter of this.#waiters.splice(0)) waiter.reject(error);
	}

	#scheduleRestart(): void {
		// Once close has begun nothing may start again, whoever asked (an exit listener may close).
		if (this.#closing) return;
		const delay = this.#backoff;
		this.#backoff = Math.min(this.#backoff * 2, MAX_RESTART_MS);
		this.#restart = setTimeout(() => void this.#restartNow(), delay);
		// An idle client does not keep the process alive; a call waiting for the restart does (see #ready).
		if (this.#waiters.length === 0) this.#restart.unref();
	}

	async #restartNow(): Promise<void> {
		try {
			const host = await start(this.#launch, (child) => {
				this.#child = child;
			});
			if (this.#closing) {
				host.child.stdin?.end();
				return;
			}
			this.#adopt(host);
		} catch (failure) {
			if (this.#closing) return;
			const error = failure instanceof AttemptFailed ? failure.error : (failure as Error);
			const exit = failure instanceof AttemptFailed ? failure.exit : undefined;
			const retryable =
				error instanceof RuiUnavailableError || (error instanceof RuiStartError && RETRYABLE_START_CODES.has(error.code));
			if (exit) this.emit("exit", { ...exit, restarting: retryable });
			this.#fail(new RuiUnavailableError(`the Rui Host could not restart: ${error.message}`, { cause: error }));
			if (retryable) return this.#scheduleRestart();
			this.#dead = new RuiUnavailableError(`the Rui Host cannot restart: ${error.message}`, { cause: error });
			disposeLaunch(this.#launch);
		}
	}
}

export function launchFor(settings: HostSettings, runtimeDir: string, options: ClientOptions = {}): Launch {
	// Inherit program/home lookup plus only the secret sources this document names.
	const env: NodeJS.ProcessEnv = Object.create(null);
	for (const name of ["PATH", "HOME", "TMPDIR"]) {
		const value = process.env[name];
		if (value !== undefined) env[name] = value;
	}
	let document = pipeSettings(settings, (source, path) => {
		const name = environmentName(source, path);
		if (name === undefined) return;
		const value = process.env[name];
		if (value !== undefined) env[name] = value;
	});
	let interfaceDir: Launch["interfaceDir"] = runtimeDir;
	let detached = false;
	if (document !== null && typeof document === "object" && !Array.isArray(document)) {
		if (Object.hasOwn(document, "presets") && document.presets !== undefined) {
			// Presets retain their existing friendly spec writer after settings normalization.
			const presets = document.presets as HostSettings["presets"];
			document = { ...document, presets: Object.fromEntries(Object.entries(presets!).map(([name, spec]) => [name, presetFor(spec)])) };
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
	return {
		binary: resolveBinary(options.binary), document: encodeSettings(document), interfaceDir,
		socketPath: join(runtimeDir, "interface", SOCKET_NAME), env, detached,
	};
}

/** Release all restart-owned secret bytes/references on every terminal transition. */
function disposeLaunch(launch: Launch): void {
	launch.document.fill(0);
	for (const name of Object.keys(launch.env)) delete launch.env[name];
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

/** Presets and Session mutation requests use the same wire writer. */
function presetFor(spec: AgentSpec): Schemas["AgentSpec"] {
	return agentSpec(spec) as Schemas["AgentSpec"];
}

/** Starts one child and resolves once it answers host-info, or throws AttemptFailed. */
async function start(launch: Launch, spawned: (child: ChildProcess) => void): Promise<Host> {
	let child: ChildProcess;
	try {
		child = spawn(launch.binary, ["host", "serve", "--settings", "-"], {
			env: launch.env,
			stdio: ["pipe", "pipe", "inherit"],
		});
	} catch (error) {
		throw new AttemptFailed(new RuiUnavailableError(`could not start ${launch.binary}`, { cause: error }), undefined);
	}
	spawned(child);
	const stdout: Buffer[] = [];
	// This fixed prefix precedes every caller-controlled path in the child's record.
	const receipt = Buffer.alloc(READINESS_RECEIPT_BYTES);
	let receiptBytes = 0;
	let readyInstance: string | undefined;
	let outputBytes = 0;
	const capture = (chunk: Buffer) => {
		if (receiptBytes < receipt.length) {
			receiptBytes += chunk.copy(receipt, receiptBytes, 0, receipt.length - receiptBytes);
			if (receiptBytes === receipt.length) readyInstance = readinessInstance(receipt);
		}
		if (outputBytes + chunk.length <= 64 * 1024) {
			stdout.push(chunk);
			outputBytes += chunk.length;
		} else chunk.fill(0);
	};
	child.stdout?.on("data", capture);
	const outputEnded = new Promise<void>((done) => child.stdout?.once("close", done));
	const launchError = new Promise<Error>((done) => child.once("error", done));
	const exited = exitOf(child);
	// The child must not keep this process alive; its stdin closing is how it learns this process ended.
	child.unref();
	(child.stdout as Socket | null)?.unref();
	(child.stdin as unknown as Socket | null)?.unref();
	child.stdin?.on("error", () => {});
	// write owns this copy until its callback; retain the restart document separately.
	const bytes = Buffer.from(launch.document);
	const wipeWrite = () => bytes.fill(0);
	child.stdin?.once("close", wipeWrite);
	child.stdin?.write(bytes, () => {
		bytes.fill(0);
		child.stdin?.off("close", wipeWrite);
	});

	try {
		let ended: Exit | Error | undefined;
		void exited.then((exit) => (ended ??= exit));
		void launchError.then((error) => (ended ??= error));
		while (ended === undefined) {
			const info = readyInstance === undefined ? undefined : await probe(launch, readyInstance).catch(async (error: unknown) => {
				if (error instanceof ConnectionError) return undefined;
				child.kill("SIGKILL");
				throw new AttemptFailed(error as Error, await exited);
			});
			if (info) return { child, instance: info.instance, info, exited };
			await sleep(READY_POLL_MS);
		}
		if (ended instanceof Error) {
			throw new AttemptFailed(new RuiUnavailableError(`could not start ${launch.binary}: ${ended.message}`, { cause: ended }), undefined);
		}
		// The refusal line is written before the exit; give the pipe a moment to deliver it.
		await Promise.race([outputEnded, sleep(1_000)]);
		const output = Buffer.concat(stdout);
		let refusal: RuiStartError | undefined;
		try {
			refusal = startError(output.toString("utf8"));
		} finally {
			output.fill(0);
		}
		throw new AttemptFailed(
			refusal ?? new RuiUnavailableError(`rui exited before it was ready (code ${ended.code}, signal ${ended.signal})`),
			ended,
		);
	} finally {
		child.stdout?.off("data", capture);
		child.stdout?.on("data", (chunk: Buffer) => chunk.fill(0));
		receipt.fill(0);
		for (const chunk of stdout) chunk.fill(0);
		stdout.length = 0;
	}
}

/** Readiness proves the Host admitted the path; decoding and alias effects belong after it. */
async function createInterfaceAlias(launch: Launch): Promise<void> {
	const dir = launch.interfaceDir;
	const target = typeof dir === "string" ? dir : Buffer.from(dir.hex, "hex");
	// An ASCII alias lets Node's string-only socket API reach OS-byte directories.
	await symlink(target, dirname(launch.socketPath));
}

async function probe(launch: Launch, instance: string): Promise<HostInfo | undefined> {
	await (launch.aliasReady ??= createInterfaceAlias(launch));
	try {
		await stat(launch.socketPath);
	} catch {
		return undefined;
	}
	const body = JSON.stringify({
		version: WIRE_VERSION,
		kind: "host_info",
		store: "",
	} satisfies Schemas["HostInfoRequest"]);
	const reply = await post({ socketPath: launch.socketPath, path: "/v1/host-info", body, instance });
	const info = JSON.parse(reply.toString("utf8")) as HostInfo;
	if (info.instance !== instance) throw new RuiUnavailableError("the Host socket did not match the started child's readiness instance");
	return info;
}

/** One length-prefixed JSON frame: a 4-byte big-endian length, then UTF-8 JSON (D130). */
export function encodeSettings(document: Schemas["HostSettings"]): Buffer {
	const json = Buffer.from(JSON.stringify(document));
	try {
		const out = Buffer.alloc(4 + json.length);
		out.writeUInt32BE(json.length, 0);
		json.copy(out, 4);
		return out;
	} finally {
		json.fill(0);
	}
}

/** Only the fixed leading child receipt is authoritative; later path bytes are not records. */
export function readinessInstance(prefix: Buffer): string | undefined {
	if (prefix.length !== READINESS_RECEIPT_BYTES) return undefined;
	return /^ready instance=([0-9a-f]{32}) $/.exec(prefix.toString("latin1"))?.[1];
}

/** The refusal a child wrote as its one stdout line, `{"rui_start_error":{code,message}}` (D211). */
export function startError(output: string): RuiStartError | undefined {
	for (const line of output.split("\n").reverse()) {
		if (!line.trim()) continue;
		try {
			const parsed: Partial<Schemas["StartError"]> | null = JSON.parse(line);
			const refusal = parsed?.rui_start_error;
			if (refusal && typeof refusal.code === "string") {
				return new RuiStartError(refusal.code, typeof refusal.message === "string" ? refusal.message : refusal.code);
			}
		} catch {
			// Not the refusal line.
		}
	}
	return undefined;
}

function exitOf(child: ChildProcess): Promise<Exit> {
	if (child.exitCode !== null || child.signalCode !== null) {
		return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
	}
	return new Promise((done) => child.once("exit", (code, signal) => done({ code, signal })));
}
