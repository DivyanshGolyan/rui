// Rui.connect starts the Host as a child of this process, hands it the launch
// frame on stdin and waits until it answers host-info on the socket in its
// private runtimeDir (D107, D112, D130, D131). The child lives as long as its
// stdin stays open (D5, D118). A child that exits on its own is restarted with
// capped backoff, and calls in flight are retried once the new Host is ready;
// every write carries a request key, so a retry is safe (D118, D129).
import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtemp, realpath, rm, stat } from "node:fs/promises";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { RuiStartError, RuiUnavailableError } from "./errors.ts";
import { models, Session, Sessions, setPaused, type ModelSummary } from "./sessions.ts";
import { ConnectionError, post, WIRE_VERSION } from "./transport.ts";
import type { components } from "./wire.ts";

export interface ConnectOptions {
	/** The Store: a SQLite Store directory today. The MySQL URL arrives with the Store's MySQL support. */
	database: string;
	/** The OpenAI-compatible provider. Only the key Adapter is offered to a launched Host (D149). */
	provider: { baseUrl: string; key: string };
	/** How many Turns may run at once. Left out, the Host picks its default. */
	activeCapacity?: number;
	/** How long connect keeps retrying while another Host holds the Store (D183, D198). Default 120 000. */
	lockWaitMs?: number;
	/** The `rui` executable. Default: `rui` on PATH. */
	binary?: string;
}

/** Fires on every child exit, including one the client restarts from (D129). */
export interface ExitEvent {
	code: number | null;
	signal: NodeJS.Signals | null;
	restarting: boolean;
}

type HostInfo = components["schemas"]["HostInfoReply"];

const FRAME_VERSION = 1;
const SOCKET_NAME = "rui.sock";
const DEFAULT_LOCK_WAIT_MS = 120_000;
const LOCK_RETRY_MS = 500;
const FIRST_RESTART_MS = 500;
const MAX_RESTART_MS = 30_000;
/** The Host bounds its own shutdown at 10 s (D118); this leaves room for the exit to arrive. */
const CLOSE_GRACE_MS = 15_000;
const READY_POLL_MS = 25;
/** How long a refused connection waits for the child's exit before it counts as unanswered. */
const EXIT_NOTICE_MS = 2_000;
/** Refusals a restart cannot fix: the same frame would be refused again. */
const RETRYABLE_START_CODES = new Set(["store_locked", "store_fenced"]);

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
	frame: object;
	socketPath: string;
	store: string;
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
	/** Create and list Sessions. */
	readonly sessions: Sessions = new Sessions(this);

	private constructor(launch: Launch, runtimeDir: string, host: Host) {
		super();
		this.#launch = launch;
		this.#runtimeDir = runtimeDir;
		this.#adopt(host);
	}

	/** Starts Rui as a child of this process and resolves once it is ready. */
	static async connect(options: ConnectOptions): Promise<Rui> {
		const runtimeDir = await mkdtemp(join(tmpdir(), "rui-"));
		try {
			const launch = launchFor(options, runtimeDir);
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
		if (child && child.exitCode === null && child.signalCode === null) {
			const exited = exitOf(child);
			child.stdin?.end();
			const timer = setTimeout(() => child.kill("SIGKILL"), CLOSE_GRACE_MS);
			const exit = await exited;
			clearTimeout(timer);
			this.emit("exit", { ...exit, restarting: false });
		}
		await rm(this.#runtimeDir, { recursive: true, force: true });
	}

	/**
	 * Sends one request to the ready Host. A call that finds the child gone
	 * waits for the restarted Host and is sent once more. Internal: the
	 * package's calls are built on it.
	 */
	async call(path: string, body: string, environment?: Buffer, prefixBytes?: number): Promise<Buffer> {
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
					...(prefixBytes !== undefined ? { prefixBytes } : {}),
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
	async exchange(path: string, build: (store: string) => string, environment?: Buffer, prefixBytes?: number): Promise<Buffer> {
		const host = await this.#ready();
		return this.call(path, build(host.info.store), environment, prefixBytes);
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
		}
	}
}

function launchFor(options: ConnectOptions, runtimeDir: string): Launch {
	// A URL is passed through; anything else is a SQLite Store directory.
	const store = /^[a-z][a-z0-9+.-]*:\/\//i.test(options.database) ? options.database : resolve(options.database);
	const frame = {
		v: FRAME_VERSION,
		store,
		runtimeDir,
		...(options.activeCapacity === undefined ? {} : { activeCapacity: options.activeCapacity }),
		provider: { kind: "openai_key", baseUrl: options.provider.baseUrl, key: options.provider.key },
	};
	// The child gets only what it needs to find programs and its home (D185).
	const env: NodeJS.ProcessEnv = {};
	for (const name of ["PATH", "HOME", "TMPDIR"]) {
		const value = process.env[name];
		if (value !== undefined) env[name] = value;
	}
	return { binary: options.binary ?? "rui", frame, socketPath: join(runtimeDir, SOCKET_NAME), store, env };
}

/** Starts one child and resolves once it answers host-info, or throws AttemptFailed. */
async function start(launch: Launch, spawned: (child: ChildProcess) => void): Promise<Host> {
	let child: ChildProcess;
	try {
		child = spawn(launch.binary, ["host", "serve", "--launch-frame"], {
			env: launch.env,
			stdio: ["pipe", "pipe", "inherit"],
		});
	} catch (error) {
		throw new AttemptFailed(new RuiUnavailableError(`could not start ${launch.binary}`, { cause: error }), undefined);
	}
	spawned(child);
	const stdout: Buffer[] = [];
	child.stdout?.on("data", (chunk: Buffer) => stdout.push(chunk));
	const outputEnded = new Promise<void>((done) => child.stdout?.once("close", done));
	const launchError = new Promise<Error>((done) => child.once("error", done));
	const exited = exitOf(child);
	// The child must not keep this process alive; its stdin closing is how it learns this process ended.
	child.unref();
	(child.stdout as Socket | null)?.unref();
	(child.stdin as unknown as Socket | null)?.unref();
	child.stdin?.on("error", () => {});
	child.stdin?.write(encodeFrame(launch.frame));

	let ended: Exit | Error | undefined;
	void exited.then((exit) => (ended ??= exit));
	void launchError.then((error) => (ended ??= error));
	while (ended === undefined) {
		const info = await probe(launch).catch((error: unknown) => {
			if (error instanceof ConnectionError) return undefined;
			child.kill("SIGKILL");
			throw new AttemptFailed(error as Error, undefined);
		});
		if (info) return { child, instance: info.instance, info, exited };
		await sleep(READY_POLL_MS);
	}
	if (ended instanceof Error) {
		throw new AttemptFailed(new RuiUnavailableError(`could not start ${launch.binary}: ${ended.message}`, { cause: ended }), undefined);
	}
	// The refusal line is written before the exit; give the pipe a moment to deliver it.
	await Promise.race([outputEnded, sleep(1_000)]);
	const refusal = startError(Buffer.concat(stdout).toString("utf8"));
	throw new AttemptFailed(
		refusal ?? new RuiUnavailableError(`rui exited before it was ready (code ${ended.code}, signal ${ended.signal})`),
		ended,
	);
}

async function probe(launch: Launch): Promise<HostInfo | undefined> {
	try {
		await stat(launch.socketPath);
	} catch {
		return undefined;
	}
	// The Host names a SQLite Store by its canonical path, which exists once the socket does.
	let store = launch.store;
	if (!store.includes("://")) {
		try {
			store = await realpath(store);
		} catch {
			return undefined;
		}
	}
	const body = `{"version":${JSON.stringify(WIRE_VERSION)},"kind":"host_info","store":${JSON.stringify(store)}}`;
	const reply = await post({ socketPath: launch.socketPath, path: "/v1/host-info", body });
	return JSON.parse(reply.toString("utf8")) as HostInfo;
}

/** One length-prefixed JSON frame: a 4-byte big-endian length, then UTF-8 JSON (D130). */
export function encodeFrame(frame: object): Buffer {
	const json = Buffer.from(JSON.stringify(frame));
	const out = Buffer.alloc(4 + json.length);
	out.writeUInt32BE(json.length, 0);
	json.copy(out, 4);
	json.fill(0);
	return out;
}

/** The refusal a child wrote as its one stdout line, `{"rui_start_error":{code,message}}` (D211). */
export function startError(output: string): RuiStartError | undefined {
	for (const line of output.split("\n").reverse()) {
		if (!line.trim()) continue;
		try {
			const parsed = JSON.parse(line) as { rui_start_error?: { code?: unknown; message?: unknown } };
			const refusal = parsed.rui_start_error;
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
