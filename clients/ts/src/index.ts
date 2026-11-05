// The package's public surface. Transport types stay internal (D19).
export { Rui, type ConnectOptions, type ExitEvent, type McpServer } from "./client.ts";
export { RuiRequestError, RuiStartError, RuiUnavailableError } from "./errors.ts";
export {
	Session,
	Sessions,
	type AgentSpec,
	type SessionCreate,
	type ModelSummary,
	type SendOptions,
	type SessionSpec,
	type SessionSummary,
	type SessionStatus,
	type SessionUpdate,
	type WriteOptions,
} from "./sessions.ts";
export { FEED_KINDS, INLINE_TEXT_BYTES, type FeedEntry, type FeedKind, type ListActivityOptions, type SearchActivityOptions, type ActivitySearchEntry } from "./feed.ts";
