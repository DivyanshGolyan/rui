# Codex subscription feasibility result

Date: 2026-08-29

## Verdict

**Go for the capacity-one OnePage V1 provider path.** The pinned Codex subscription protocol has
produced successful streamed model responses and completed the controlled live repair through the
ordinary Harness, Bash, `apply_patch`, and durable follow-up turn. The implementation does not need a
provider registry, model catalog, response transaction API, or resumable provider stream.

**No-go for a 100-active-call release claim until the concurrency slope is measured.** The capacity-one
live tracer records compiled adapter bounds, whole-process RSS and physical footprint, whole-process
virtual stack reservation sampled while TCP is active, threads, and observable macOS TCP queue evidence.
That single-call observation is not a
substitute for issue #43's production-shaped 1, 10, 50, and 100 call matrix or complete kernel socket
accounting. See [the transport memory budget](model-transport-memory-budget.md).

## Pinned protocol

| Decision | V1 result |
| --- | --- |
| Adapter version | `onepage-codex-responses-v1@6478a751` |
| Canonical response envelope | `ONERSP3`, version 3 |
| Upstream reference | OpenAI Codex commit `6478a751fde8884b2fdc76486fe23175a8e795d4` |
| Model endpoint | `POST https://chatgpt.com/backend-api/codex/responses` |
| Response protocol | Responses API request with `stream: true`; bounded SSE ingestion |
| Client identity | Truthful `originator: onepage` |
| Account binding | `chatgpt-account-id` from the access-token account claim |
| Model selection | Provider default plus the explicit Job model and reasoning binding; no adapter catalog or fallback |

Codex wire details remain private to `codex_provider` and `codex_native`. The shared model port sees
only one synchronous bounded candidate-or-failure settlement. A different adapter may use many wire
events or private Host-owned scratch without changing that port.

## Authorization and credential ownership

OnePage uses the ChatGPT device authorization flow. `--codex-login` requests a device code, opens the
verification page, polls according to the server interval, exchanges the authorization code with its
verifier, and stores the resulting token record. The whole attended login has a 15-minute deadline.

The native Host owns credentials in macOS Keychain under service `OnePage Codex` and account
`chatgpt-subscription`. Access, refresh, ID-token, and account-binding bytes stay outside Session,
Conversation, Core State, and provider-visible history. Temporary credential buffers are scrubbed.

Before dispatch, OnePage refreshes a token whose JWT expiry is near. Refresh is one synchronous HTTP
call. The replacement token must retain the same trustworthy account binding before Keychain is
updated. A rejected refresh and missing refresh authority become distinct bounded Codex diagnostic
codes. Other Keychain, allocation, parsing, or storage failures remain Host errors. OnePage does not
silently start a new attended login.

Logout attempts one bounded revocation request and always removes the local Keychain item. A remote
revocation failure cannot retain local authority.

## Retry and timeout behavior

Every device, token, refresh, revoke, and model HTTP call has a whole-request deadline of at most 300
seconds. During attended login, the device request, every poll, each interval sleep, and the token
exchange also consume one monotonic 15-minute budget. Each HTTP call and sleep is capped to the
smaller remaining limit. Reaching that overall deadline wins over a simultaneous authorization or
token response. The HTTP deadline interrupts the owned socket and joins the request task before
return; it leaves no detached work.

OnePage does not retry a model request. Failures before request start and failures after the request
may have started remain distinct. Device authorization polling is the only repeated protocol action:
it follows the returned interval, adds five seconds for `slow_down`, caps the interval at 60 seconds,
and stays within the 15-minute attended deadline.

## Bounded capture and diagnostics

| Resource | Bound |
| --- | ---: |
| Access token | 16 KiB |
| Account identifier | 128 bytes |
| Provider-neutral request window | 4,096 bytes |
| Canonical response | 98,372 bytes |
| One SSE wire frame | 598,424 bytes |
| Total SSE bytes per dispatch | 2,393,696 bytes |
| JSON nesting | 32 levels |
| Rejection body accepted for diagnostics | 4,096 bytes |
| Durable opaque diagnostic code | 64 bytes |

The adapter compacts one SSE frame in place and uses a bounded non-allocating two-pass cursor. It does
not retain a payload copy, JSON DOM arena, or complete canonical result buffer. The first valid
terminal ends the logical response, and later bytes are ignored independently of HTTP chunking.

Each retained limit owns a distinct resource. The canonical response bounds decoded semantic content
and provisional storage. The frame bounds resident parser memory and worst-case JSON escape expansion.
Total SSE bytes bound cumulative parser and transport work, while the whole-call deadline independently
bounds elapsed time. JSON depth and object-member limits bound the cursor's fixed stack and duplicate-key
storage. Tool, choice, field, and argument counts or sizes bound semantic cardinality in the model
contract. The dedicated draft-entry count bounds startup cleanup work independently of the one live
writer. There is no event-count limit: every event consumes the total byte budget, so a separate count
would reject valid fine-grained streams without bounding another resource.

Durable failure diagnostics keep the shared source generic (`local_credentials` or `provider`). The
opaque code is Codex-owned. Stable codes distinguish refresh rejection, missing refresh authority,
HTTP authentication and authorization rejection, model rejection, rate limiting, quota exhaustion,
and backend failure. Every non-success HTTP code includes its exact decimal status, for example
`codex.http.quota.429`. Raw bodies, messages, tokens, and account identifiers are never retained.

## Durable history requirements

Each provider request is rebuilt from the durable Session identity and contains the fixed
instructions, model contract, selected model, admitted Tool Catalog, and ordered Conversation entries.
A Tool Call and Tool Result must remain adjacent; context selection cannot split the pair. The exact
canonical Tool Result, including bounded Base64 output fields, reaches the next model turn.

Capability advertisement follows durable lifecycle support. Until issue #38 supplies the Interaction
Request layer, the live Codex request offers only the admitted Tool Catalog and does not advertise the
synthetic `input_request` function. The strict Codex-private decoder remains in place so unexpected or
future provider input dispositions fail closed without changing the shared response format.

A drive that admits externally produced Completion evidence returns before the next causally
dependent Provider or Tool dispatch. The deterministic restart test closes immediately after Tool
Result admission, creates a fresh provider and Harness, reconstructs the exact result, proves the tool
executed once, and then commits a durable Final Answer. Restore needs only the Session identity; there
is no resume token or public progress boundary.

## Remaining release evidence

The functional feasibility question is closed and the capacity-one command now produces the required
report. One successful recorded run of that command remains the final issue #11 evidence. The concurrency
and physical-memory slope belongs to issue #43, which must run the opt-in matrix described in the
transport memory budget before claiming support for 100 simultaneous active Codex calls. Keep that work
focused on the real vertical slice; do not replace the gate with a deterministic local server or
extrapolate from one whole-process peak that cannot isolate TLS, stack, allocator, and socket costs.
