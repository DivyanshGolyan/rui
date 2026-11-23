// The Transcript hub, TS side (sketch, U11). Spokes (readers of foreign formats) produce
// it; `importTranscript` is its only consumer and sends it to the Host's import doors.
// The Host is the importer into the Store; this file only frames and resumes.

export const TRANSCRIPT_VERSION = 1 as const;

export interface TranscriptSource {
	/** e.g. "pi-durable" */
	system: string;
	/** The foreign version the reader read, e.g. "1.4.0". */
	systemVersion: string;
	/** Stable per foreign conversation; keys the import, so lazy and eager imports meet. */
	id: string;
}

export type TranscriptPart =
	| { type: "text"; text: string }
	| { type: "image"; mediaType: "image/png" | "image/jpeg"; bytes: Uint8Array };

export type TranscriptAssistantItem =
	| { type: "text"; text: string }
	| { type: "reasoning"; family: string; bag: string }
	| { type: "tool_call"; callId: string; name: string; argumentsJson: string };

/** One item. `head` points backward by item ordinal, never by foreign id. */
export type TranscriptItem =
	| { type: "user"; parts: TranscriptPart[] }
	| { type: "assistant"; family: string; model: string; items: TranscriptAssistantItem[]; inputTokens?: number; outputTokens?: number }
	| { type: "tool_result"; callId: string; parts: TranscriptPart[]; isError: boolean }
	| { type: "instructions"; text: string }
	| { type: "head"; headOrdinal: number; text?: string };

/** A reader's output: items in order, pulled lazily so large histories stream. */
export interface Transcript {
	readonly version: typeof TRANSCRIPT_VERSION;
	readonly source: TranscriptSource;
	items(): AsyncIterable<TranscriptItem>;
}

export interface ImportReport {
	session: string;
	items: number;
	/** Reasoning bags from a provider family the Session's codec does not accept. */
	droppedReasoning: number;
	/** True when an earlier import had already sealed this source. */
	alreadyImported: boolean;
}

/**
 * Begin (creates the Session from `spec`, or returns the one this source already has),
 * append chunks from `next_ordinal` (≤ 8 MiB each; skipped items are not resent), seal.
 * Safe to rerun after a crash at any point.
 */
export function importTranscript(_rui: unknown, _transcript: Transcript, _spec: unknown): Promise<ImportReport> {
	throw new Error("not implemented");
}
