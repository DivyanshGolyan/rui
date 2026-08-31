# OpenCode V2 server API interface

Research date: 2026-08-29

Primary source: `anomalyco/opencode`

Pinned V2 revision: [`8ba434b5973856b2f32b8cd3543e154b25c413e6`](https://github.com/anomalyco/opencode/tree/8ba434b5973856b2f32b8cd3543e154b25c413e6) (`v2`, committed 2026-08-29)

Official generated reference: [OpenCode V2 API](https://opencode.ai/v2/docs/api/) and [OpenAPI JSON](https://opencode.ai/v2/openapi.json)

## Executive summary

OpenCode V2 exposes a high-level, stateful agent-host API. It is not a thin provider or chat-completions facade. A client creates or adopts a Session, durably admits prompts, subscribes to live events or a durable per-Session log, renders projected messages, and answers server-owned permission and form requests. The Server owns the agent loop, provider calls, tool discovery and execution, compaction, retries, interruption, restart recovery, and persistence.

The public contract has three coordinated representations:

1. an Effect `HttpApi` is the source of truth for methods, paths, schemas, errors, and middleware;
2. a generated OpenAPI 3.1 document describes the HTTP surface;
3. generated Promise and Effect TypeScript clients expose the same routes, with an in-process SDK running the same assembled router without a network listener.

At this pin the official OpenAPI document contains 115 paths, 136 operations, and 223 schemas. The downloaded official JSON byte-matches the committed file (SHA-256 `c24fb10f8f0a2f802bffb47c9c7f393abf5f815cb1db9d8619377c31524bf52c`). The surface calls itself experimental, uses `v2.*` operation identifiers, and lives on the V2 branch, but its document version is `0.0.1` and the matching published client is the beta `@opencode-ai/client@0.0.0-beta-18684`. “V2” is therefore the beta implementation/protocol generation, not a stable HTTP major-version prefix: paths are under `/api`, not `/v2` ([official generated reference](https://opencode.ai/v2/docs/api/), [API assembly](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/api.ts#L128-L191), [committed OpenAPI](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/openapi.json)).

## Contract and hosting model

Protocol assembles every route group into one typed `HttpApi`, then applies authorization and schema-error middleware globally. Server supplies the concrete Location and Session-Location middleware and publishes the generated OpenAPI at `/openapi.json` ([Protocol API composition](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/api.ts#L128-L191), [Server route assembly](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/routes.ts#L114-L159)).

The same application can be hosted in three ways:

- the managed Node service binds a listener, defaults to `127.0.0.1`, starts at port 4096 when no port is fixed, requires a password, and resumes Sessions with unreleased execution claims after boot;
- the fetch adapter returns a web-standard `(Request) -> Response` handler for Workerd, Deno, Bun, or tests; it may be unauthenticated when the embedder omits a password and must then be protected by the embedder;
- `@opencode-ai/sdk` calls the same assembled HTTP router in process, with no listener or network hop.

See the [managed-process lifecycle](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/process.ts#L49-L145), [fetch-host contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/fetch.ts#L19-L53), and [SDK Promise adapter](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/sdk/src/promise.ts#L8-L37).

## HTTP endpoint inventory

The [official reference](https://opencode.ai/v2/docs/api/) and byte-identical [committed OpenAPI document](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/openapi.json) are the complete inventory. At the pin they have 136 operations across 29 API groups. The largest groups are Session 40, Integration 11, persistent PTY 11, Form 7, Permission 7, PTY 7, MCP 6, Shell 6, and VCS 5. This section groups the interface by what an agent client needs rather than repeating every generated schema.

### Agent lifecycle and transcript

| Area | Operations |
| --- | --- |
| Service | `GET /api/health`, `GET /api/server`, `GET /api/location` |
| Session collection | `GET /api/session`, `GET /api/session/stats`, `GET /api/session/active`, `POST /api/session`, `POST /api/session/import` |
| Session identity/lifecycle | `GET`, `DELETE /api/session/:sessionID`; `GET .../export`; `POST .../fork`, `.../rename`, `.../move`, `.../agent`, `.../model`, `.../view` |
| Input and execution | `POST .../prompt`, `.../synthetic`, `.../skill`, `.../command`, `.../shell`, `.../compact`, `.../interrupt`, `.../background`, `.../wait` |
| Pending input | `GET .../inbox`; `DELETE .../inbox/:inboxID`; `POST .../inbox/:inboxID/steer` or `/queue` |
| Transcript/context | `GET .../message`, `GET .../message/:messageID`, `PATCH .../message/:messageID`, `GET .../context` |
| Session-owned configuration | `GET/PUT/DELETE .../instructions/entries[/key]`, `PUT .../environment` |
| Revert | `POST .../revert/stage`, `.../revert/clear`, `.../revert/commit` |
| Streams and transient generation | `GET /api/event`, `GET /api/experimental/session/:sessionID/log`, `POST .../generate`, `POST /api/generate` |

The generated reference presents 40 Session operations, including the paginated message-list operation defined in the separate Message group. Their exact request, response, and error contracts are in [Session Protocol](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L129-L759) and [Message Protocol](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/message.ts#L7-L58).

### Human interaction gates

| Area | Operations |
| --- | --- |
| Pending permissions | `GET /api/permission/request`, `GET /api/session/:sessionID/permission`, `GET .../permission/:requestID` |
| Permission decisions | `POST .../permission` to evaluate/create; `POST .../permission/:requestID/reply` |
| Saved permissions | `GET /api/permission/saved`, `DELETE /api/permission/saved/:id` |
| Pending forms | `GET /api/form/request`, `GET /api/session/:sessionID/form`, `GET .../form/:formID`, `GET .../form/:formID/state` |
| Form decisions | `POST .../form` to create; `POST .../form/:formID/reply` or `/cancel` |

There is no public V2 `question.*` route or event. The built-in `question` tool first asserts the `question` permission, converts each question to a Form field, waits on the Form, and converts the answer back to tool content. Clients should therefore implement the Form API, not the legacy Question API ([question-tool adapter](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/tool/plugin/question.ts#L10-L127), [Form routes](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/form.ts#L37-L143)).

### Catalog, providers, tools, and configuration

| Area | Operations |
| --- | --- |
| Agent surface | `GET /api/agent`, `GET /api/agent/:agentID`; `GET /api/command`; `GET /api/skill`; `GET /api/plugin`; `GET /api/reference` |
| Provider/model catalog | `GET /api/provider`, `GET /api/provider/:providerID`, `GET /api/model`, `GET /api/model/default` |
| Integration auth | list/get integrations; add experimental well-known source; connect with key; start/status/complete/cancel OAuth; start/status/cancel command auth |
| Credentials | `PATCH /api/credential/:credentialID`, `POST .../activate`, `DELETE ...` |
| MCP | list/add/remove/connect/disconnect servers and list resource catalog |
| Configuration | `GET /api/config` |
| Web search | list providers and execute a search |

The public catalog is descriptive. Provider records expose identity, package, activation, optional integration, and request overlays; Model records expose a provider-qualified reference, capabilities, variants, status, token limits, compatibility flags, release time, and costs ([Provider schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/provider.ts#L7-L61), [Model schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/model.ts#L8-L140), [Provider routes](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/provider.ts#L8-L45), [Model routes](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/model.ts#L8-L44)).

There is no public endpoint where the UI registers a tool or submits an ordinary tool result. Server-side plugins and MCP populate the tool catalog, and the Server executes tools as part of the agent loop. The public interface exposes their lifecycle through Session messages/events and exposes only human gates such as permissions and forms. This is a material boundary: a compatible client is a controller/viewer for the OpenCode host, not a tool executor.

`GET /api/config` is also descriptive, not an update endpoint. It returns discovered documents/directories from lowest to highest priority. The schema covers model/agent defaults, permission rules, provider overlays, plugins, MCP, commands, skills, instructions, references, compaction, tool-output policy, formatter/LSP/watcher/media, and experimental settings ([Config route](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/config.ts#L6-L22), [Config schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/config.ts#L24-L134)).

### Local development environment

The remaining route families make the Server a workstation/runtime host rather than only an agent transcript service:

- filesystem read/list/find;
- VCS identity/base/status/branches/diff;
- Project list/update/current;
- Worktree list/create/remove/refresh;
- Workspace create/destroy;
- Shell list/create/get/timeout/output/remove;
- ephemeral PTY list/create/get/update/remove/connect-token/WebSocket-connect;
- experimental persistent terminal read/list/create/get/update/snapshot/remove/connect-token/WebSocket-connect plus global handoff/shutdown;
- debug Location list/evict and V1 migration status.

These operations account for a large part of the 136-route surface and show that OpenCode's Server API includes workspace orchestration and terminals, not just conversation state.

## Location and Session routing

Many catalog and environment routes are Location-scoped. A client selects a Location with the deep-object query `location[directory]` and/or `location[workspace]`, or with `x-opencode-directory` and `x-opencode-workspace` headers. If no directory is supplied the Server uses its process working directory. Location-scoped responses commonly include both resolved Location information and `data` ([Location query contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/location.ts#L5-L43), [request resolution](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/location.ts#L69-L99)).

Session-scoped routes do not trust a caller-supplied directory. Middleware looks up the Session's stored directory/workspace and loads that Location's service graph before executing the handler ([Session Location middleware](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/middleware/session-location.ts#L9-L29), [Session lookup](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/location.ts#L34-L52)). The global `/api/event` stream is deliberately not Location-filtered; events carry optional Location metadata so one client can update multiple Locations ([event architecture](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/specs/v2/event-stream-architecture.md#L25-L46)).

## Session admission and execution semantics

`POST /api/session/:sessionID/prompt` accepts an optional caller-generated message ID plus text, file/agent/skill attachments, metadata, delivery mode, and `resume`. Its response is the admitted `SessionInbox.User`; it does not wait for an assistant answer. Admission durably records `session.inbox.enqueued` before advisory execution begins ([prompt endpoint](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L337-L357), [Session contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/specs/v2/session.md#L5-L23)).

The two delivery modes are semantically distinct:

- `steer` is the default and is delivered at the next safe step boundary;
- `queue` remains pending until an idle boundary;
- steers have priority, while compaction and move controls form delivery boundaries;
- `resume: false` changes scheduling only: the input remains durable but does not wake execution.

Caller-provided user/synthetic inbox IDs are idempotency keys. Reuse in the same Session and type adopts the first admission and ignores retried payload changes; cross-Session or cross-type reuse conflicts. After delivery, reconciliation uses the projected message rather than requiring the enqueue event ([Session contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/specs/v2/session.md#L5-L23)).

`POST .../wait` waits for the loop to become idle, while `POST .../interrupt` interrupts execution owned by this process and reports whether anything was interrupted. The stream/log is the richer way to observe output; `wait` is only an idle barrier ([wait and interrupt routes](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L462-L476), [interrupt route](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L665-L684)).

The managed host writes an execution claim and resumes Sessions whose claim was not released after restart. The contract explicitly does not promise exactly-once provider requests or tool effects; recovery is bounded and may encounter external-effect uncertainty ([Session recovery contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/specs/v2/session.md#L43-L55), [managed restart continuity](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/process.ts#L230-L237)).

## Messages and content parts

The durable/public projected transcript is not a simple `{ role, text }` list. Every message has a stable `msg_` ID, optional metadata, and creation time. The message union contains:

- agent/model/location switches;
- user and synthetic text;
- system updates;
- skill activation;
- shell lifecycle entries;
- assistant messages;
- compaction entries.

An assistant message fixes agent and model and holds an ordered `content` array. Content is one of:

- text, with optional provider state;
- reasoning, with optional provider state and timing;
- tool, with call ID, name, optional execution/provider state, timestamps, and a state machine.

Tool state progresses through `streaming` raw input, `running` decoded input and live metadata, then terminal `completed` or `error`. Terminal success contains a non-empty array of canonical content parts; failure contains a typed Session error and may include partial content. Canonical tool content is currently text or file `{ uri, mime, name? }` ([Session message schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session-message.ts#L22-L235), [tool content schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/tool.ts#L56-L85)).

Assistant completion also carries optional finish reason, raw provider finish, provider state, cost, tokens, retry, error, snapshots, changed files, provider-stream completion time, and final completion time. A client should treat these optional fields as lifecycle/provenance, not infer completion merely because some text arrived ([Assistant schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session-message.ts#L203-L235)).

`GET .../message` is cursor-paginated, with `asc` or `desc` ordering and a 1–200 limit. `GET .../context` is a different projection: active model context after the last compaction, not necessarily the complete visible transcript ([Message list contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/message.ts#L7-L58), [context route](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L513-L525)).

## Event transport: volatile global feed and durable Session log

OpenCode exposes two SSE contracts with different guarantees.

### `/api/event`: global, live, and lossy

`GET /api/event` emits typed native events as JSON in SSE `data:` frames. Every event has an ID, type, data, and optional metadata/Location. A new connection gets a synthetic `server.connected` first, then live events; the Server sends a comment heartbeat every 15 seconds ([event schema and endpoint](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/event.ts#L7-L55), [event handler](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/handlers/event.ts#L9-L36)).

This feed is explicitly volatile. Events before connection or during disconnection are missed. Each connection has an independent 4,096-frame dropping queue; when a slow reader exceeds it, only that connection fails, the overflow-causing event is dropped for it, and healthy connections continue in order. There is no cursor or resume token for this endpoint ([feed implementation](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/event-feed.ts#L7-L91), [delivery law](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/specs/v2/event-stream-architecture.md#L47-L64)).

The public manifest includes Session lifecycle/content/tool events plus catalog, credentials, integrations, permissions, forms, filesystem, plugins, projects, worktrees, configuration, skills, PTYs, shells, status, TUI, installation, VCS, and MCP changes. It intentionally filters internal events ([public event manifest](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/event-manifest.ts#L39-L80)).

### `/api/experimental/session/:sessionID/log`: durable and cursorable

The per-Session log accepts an exclusive aggregate sequence in `after`; with `follow=true` it replays durable events and continues live. The stream also emits `log.synced`, which marks the caught-up boundary ([Session log endpoint](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/groups/session.ts#L645-L664), [durable event manifest](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/durable-event-manifest.ts#L1-L7)).

Durable Session events include admission/delivery, execution, step boundaries, full terminal text/reasoning/tool values, compaction, revert, selection, instructions, and deletion. Fine-grained text/reasoning/tool-input deltas and tool progress are live-only; corresponding terminal events carry the complete replayable value. A robust client can use volatile deltas for animation while rebuilding truth from the durable log or projected messages after a gap ([text/reasoning boundaries](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session-event.ts#L369-L444), [tool boundaries](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/session-event.ts#L446-L545)).

## Permissions and forms

Permissions are action/resource evaluations with `allow`, `deny`, or `ask`. Rules are ordered wildcard rules and the last matching rule wins; absent matches default to `ask`. A pending request carries Session ID, action, resources, optional save targets, metadata, tool source, and a message. Replies are `once`, `always`, or `reject` ([Permission schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/permission.ts#L10-L65), [evaluation semantics](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/permission.ts#L87-L97)).

`always` persists the request's declared save resources as project-scoped allow rules and re-evaluates other pending requests. `reject` rejects all pending requests in the same Session; an optional reply message is model-visible corrective feedback rather than a silent decline ([permission reply behavior](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/permission.ts#L254-L307)). Pending requests themselves are in-memory and publish ephemeral `permission.asked/replied` events; saved allow rules are durable in SQLite ([pending state](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/permission.ts#L114-L141), [saved permissions](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/permission/saved.ts#L29-L82)).

Forms support string, number, integer, boolean, multiselect, and external-acknowledgement fields; validation includes requiredness, ranges, patterns, formats, option sets, and conditional visibility based on earlier fields. State is `pending`, `answered`, or `cancelled` ([Form schema](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/schema/src/form.ts#L18-L157)). Forms are also in-memory: pending forms remain until settled within the host lifetime; terminal entries are retained ten minutes; shutdown cancels pending forms. Their events are ephemeral ([Form runtime](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/form.ts#L8-L10), [cache/lifecycle](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/form.ts#L99-L109), [shutdown handling](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/core/src/form.ts#L205-L221)).

## Authentication and errors

When configured, HTTP authentication is Basic with fixed username `opencode` and the configured Server password. The middleware also accepts the same base64 `username:password` value in `auth_token`; this exists because browser WebSocket upgrades cannot set arbitrary headers. Ticketed PTY WebSocket connects bypass global credential checking and consume a short-lived connect ticket in the handler ([auth implementation](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/auth.ts#L5-L34), [authorization middleware](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/middleware/authorization.ts#L10-L67)).

The managed service refuses to start without a password. It stores the private connection URL/PID/version/password in a local service registration file, and the client library turns that into a Basic Authorization header. An embedded fetch host may deliberately omit a password ([managed start requirement](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/process.ts#L49-L68), [service discovery contract](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/client/src/service.ts#L1-L55), [header construction](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/client/src/promise/service.ts#L131-L137)).

The OpenAPI document currently declares no security scheme even though the assembled Server applies authorization middleware. Code generated from OpenAPI alone will therefore miss authentication setup; clients must use the Server/service documentation or inject the header themselves ([OpenAPI document](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/openapi.json), [global middleware](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/api.ts#L183-L191)).

Errors are typed JSON shapes with HTTP statuses: invalid request/cursor and form answer `400`, unauthorized `401`, forbidden `403`, missing resources `404`, conflicts/busy/already-settled `409`, unknown/command execution `500`, and unavailable dependencies `503`. Schema decode failures are converted to a bounded `InvalidRequestError`, not returned as raw validator failures ([error schemas](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/src/errors.ts#L4-L202), [schema-error mapping](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/middleware/schema-error.ts#L7-L20)).

## OpenAPI, generated clients, and SDK

The OpenAPI 3.1 document is generated directly from the client projection of the authoritative `HttpApi` and checked into `packages/protocol/openapi.json`; the Server independently serves its assembled API at `/openapi.json`, and the project publishes the same document and a rendered reference on the official V2 site. A stabilization pass makes generated output deterministic ([official reference](https://opencode.ai/v2/docs/api/), [OpenAPI generator](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/protocol/script/generate-openapi.ts#L1-L20), [Server OpenAPI path](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/server/src/routes.ts#L136-L153)).

`@opencode-ai/client` has:

- a zero-Effect Promise client using `fetch`, JSON, and `AsyncIterable` SSE;
- an Effect client using canonical decoded Schema values;
- generated coverage for all ordinary HTTP groups;
- custom code outside the generic generator for PTY WebSocket connections.

The Promise client accepts `baseUrl`, optional `fetch`, and default/request headers. Its SSE decoder enforces a 16 MiB event limit and exposes both the global event feed and durable Session log as async iterables ([client README](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/client/README.md), [Promise transport](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/client/src/promise/generated/client.ts#L264-L390), [client-generation source](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/client/script/build.ts#L42-L119)).

`@opencode-ai/sdk` presents the same client object over an in-memory fetch function and adds plugin registration plus deterministic close/disposal. The SDK README also documents Workerd/Durable Object hosting and requires one retained host per object lifetime ([SDK README](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/sdk/README.md), [Promise SDK](https://github.com/anomalyco/opencode/blob/8ba434b5973856b2f32b8cd3543e154b25c413e6/packages/sdk/src/promise.ts#L8-L37)).

## Minimal robust agent-client flow

A client that wants correctness rather than only a live animation should:

1. discover/connect to the Service and apply Basic auth when required;
2. resolve a Location, then list providers/models/agents as needed;
3. create or retrieve a Session;
4. start either the durable Session log with a stored `after` sequence, or the volatile global event feed plus a projected-state refresh strategy;
5. admit a prompt with a stable caller-generated message ID and keep the returned Inbox item as the admission acknowledgement;
6. render live delta events opportunistically, but reconcile terminal text/reasoning/tool state from durable events or `GET .../message` after reconnect;
7. handle `permission.asked` and `form.created` by reading the pending request and replying through the Session-scoped endpoint;
8. observe terminal execution/message state, using `wait` only as an idle barrier;
9. persist the durable aggregate sequence, not a volatile event ID, as the replay cursor.

This flow is an inference from the stated transport guarantees and route semantics, not a separately published official recipe. The crucial split is official: `/api/event` is live and lossy, while the Session log and projected messages are the recovery surfaces.

## Interface boundaries relevant to a comparison

The following facts should be held fixed when comparing another design to OpenCode V2:

- The HTTP client is outside the trust boundary that executes tools; it cannot submit arbitrary ordinary tool results.
- Prompt acceptance and assistant completion are separate phases. The prompt response proves durable admission, not completion.
- The visible transcript is a projection of richer durable Session events, and live deltas are not replay authority.
- Session messages carry product semantics beyond model roles, including selection, movement, shells, skills, compaction, provider state, costs, and snapshots.
- Permissions and questions/forms are server-owned suspended interactions surfaced to the client; their pending state is process-local even though saved permission grants are durable.
- Location is a first-class service-routing dimension, while a Session's persisted Location controls Session-scoped operations.
- Provider/model/auth/config/plugin/MCP ownership stays in the Server. The client chooses from exposed catalog records but does not own provider transport.
- The contract is broad and explicitly experimental. Matching its architecture does not require matching all 136 routes, terminal/worktree management, dynamic provider machinery, or current schema breadth.
