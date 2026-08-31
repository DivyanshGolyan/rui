# Bounded stream capture: Ghostty and industry prior art

Research date: 2026-08-30

## Decision

Do not make one complete SSE event the resident allocation unit, and do not add a pool of large
event slabs as the primary design. Keep a small fixed read window per live call, parse SSE and JSON
incrementally, and retain only potentially authoritative decoded values in adapter-private bounded
buffers that grow with actual content. The event boundary remains the validation boundary; it does
not need to be the buffering boundary.

Keep the existing header-first canonical response and provider-neutral `CandidateWriter`. Once the
event and later terminal state validate, the adapter can emit the selected decoded value through the
existing `model_protocol.write*` helper. A body-first format, mutable candidate transaction, or
file-backed spool would add another shared format or storage lifecycle without solving an additional
V1 problem. Reconsider the private buffer backend only if the 1/10/50/100 measurement gate shows that
actual decoded-candidate occupancy is material.

This lets OnePage retain its current semantic limits, including support for a 16 KiB patch and its
worst-case exact JSON spelling, without reserving 598,424 bytes for every concurrent call. A lower
40 KiB tool-arguments limit or 256 KiB wire-event limit would be a separate compatibility decision,
not a memory-management requirement.

## What one SSE event is

SSE is a line-delimited application protocol, not a network framing protocol. The HTML Standard
requires the receiver to accumulate every `data:` field, joining multiple fields with newlines, and
dispatch only on a blank line; it specifies no event-size limit
([WHATWG parsing algorithm](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation)).
A socket read can therefore contain part of an event, one event, or several events, and a legal SSE
event can be arbitrarily large unless the application imposes a limit.

The Codex protocol makes this relevant rather than theoretical. Current Codex tests represent
`response.output_text.delta` as a fragment, but represent `response.output_item.done` assistant
messages and function calls with the complete text or arguments
([assistant and delta fixtures](https://github.com/openai/codex/blob/28327355b861ab6cc76b01c7248663eb1be440cf/codex-rs/core/tests/common/responses.rs#L784-L825),
[function-call fixture](https://github.com/openai/codex/blob/28327355b861ab6cc76b01c7248663eb1be440cf/codex-rs/core/tests/common/responses.rs#L933-L942)).
Codex itself turns the byte stream into a complete `sse.data` string and then calls
`serde_json::from_str` on it
([implementation](https://github.com/openai/codex/blob/28327355b861ab6cc76b01c7248663eb1be440cf/codex-rs/codex-api/src/sse/responses.rs#L557-L608)).
That is useful compatibility evidence, but it is not the allocation strategy to copy at 100-way
concurrency.

OnePage's current 598,424-byte array follows mechanically from two independent escape layers:

```text
16,384 decoded patch bytes
-> 98,316 bytes of exact inner tool-arguments JSON at six-byte expansion
-> 98,372-byte canonical response including header and key
-> 598,424-byte SSE event allowance at another six-byte expansion plus metadata
```

See [`model_contract.zig`](../../src/model_contract.zig) and
[`codex_provider.zig`](../../src/codex_provider.zig). The arithmetic is a valid wire-work bound. It
does not imply that the wire representation must be resident.

## What the prior art actually says

### Ghostty: fixed batches, semantic classification, and one representation

Ghostty's current PTY path separates gathering bytes from parsing them with exactly four
preallocated 64 KiB buffers. Each buffer has one owner, the batch size also bounds parser lock-hold
time, and the gatherer stops reading when all four are in flight so the kernel queue applies
backpressure
([pipeline and limits](https://github.com/ghostty-org/ghostty/blob/83c56715773d2b5f0e8b1d5bee68424514bb43e3/src/termio/Exec.zig#L1268-L1408),
[full-ring behavior](https://github.com/ghostty-org/ghostty/blob/83c56715773d2b5f0e8b1d5bee68424514bb43e3/src/termio/Exec.zig#L1550-L1562)).
The count of four was measured for that PTY pipeline; it is not evidence for four 64 KiB buffers per
OnePage call. The transferable idea is that read-ahead is a small fixed working set, ownership is
explicit, and a full set stops the producer.

Ghostty's OSC parser separately keeps a 2 KiB ordinary inline buffer. Only recognized commands that
need more may allocate, every allocating capture has a caller-configurable finite cap, and growth is
explicitly clamped because a generic geometric-growth writer can allocate beyond the semantic limit
([ordinary and exceptional limits](https://github.com/ghostty-org/ghostty/blob/83c56715773d2b5f0e8b1d5bee68424514bb43e3/src/terminal/osc.zig#L306-L328),
[clamped capture](https://github.com/ghostty-org/ghostty/blob/83c56715773d2b5f0e8b1d5bee68424514bb43e3/src/terminal/osc.zig#L480-L574)).
Overflow invalidates the command and discards its remainder; it never produces a truncated
authoritative command
([overflow path](https://github.com/ghostty-org/ghostty/blob/83c56715773d2b5f0e8b1d5bee68424514bb43e3/src/terminal/osc.zig#L630-L670)).
Ghostty also decodes base64 in place when the decoded form cannot exceed the encoded form, avoiding
simultaneous encoded and decoded copies
([graphics command](https://github.com/ghostty-org/ghostty/blob/83c56715773d2b5f0e8b1d5bee68424514bb43e3/src/terminal/kitty/graphics_command.zig#L262-L290)).

For OnePage, the analogous move is to unescape the outer JSON string directly into a bounded
semantic sink while feeding the decoded bytes to the inner validator. It is not to retain the
escaped SSE JSON and the exact decoded arguments together.

### Zig already supplies the windowed JSON primitive

Zig's low-level JSON scanner is explicitly streaming, uses memory proportional only to container
nesting depth, and emits partial tokens across input-buffer boundaries
([source](https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/json/Scanner.zig#L1-L43)).
For strings, those partial token bytes are already JSON-unescaped; callers concatenate them only if
they choose an allocating API
([token contract](https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/json/Scanner.zig#L1424-L1502)).
`std.json.Reader.next()` refills transparently and `skipValue()` consumes unknown strings and
containers without assembling them
([Reader](https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/json/Scanner.zig#L1573-L1719)).

OnePage should put a small SSE projection reader in front of `std.json.Reader`: remove SSE field
syntax, expose concatenated `data:` bytes for exactly one event, and signal end-of-input at its blank
line. Use `next()`, never `nextAlloc*()`, for wire-controlled keys and values; compare partial key
tokens against known field names with a fixed matcher. Preallocate and enforce depth 32, route partial
decoded `text` or `arguments` tokens into their capped adapter-private buffers, and use `skipValue()`
for unknown open-envelope values. This is less new parser code than extending the current
complete-frame cursor into a second streaming JSON implementation. For function calls, feed the
same decoded `arguments` chunks to a second bounded streaming scanner while preserving those exact
chunks in the candidate body; semantic validation must not replace exact-byte identity.

### Framing libraries: a maximum token is necessary but not an allocation design

Netty's line decoder has a maximum frame length, fails as soon as the maximum is crossed when
configured fail-fast, and enters a discard state until the delimiter rather than continuing to grow
the buffer
([source](https://github.com/netty/netty/blob/600fd7944fbaec7cf262fe3cd6876df864d42881/codec/src/main/java/io/netty/handler/codec/LineBasedFrameDecoder.java#L42-L166)).
Go's `bufio.Scanner` makes the same trade: its default maximum token is 64 KiB, its buffer doubles
only up to the configured maximum, and it returns `ErrTooLong` at the cap
([API](https://pkg.go.dev/bufio#Scanner.Buffer),
[source](https://github.com/golang/go/blob/603439a1c6f2d37c7f02e246342847056ed04c21/src/bufio/scan.go#L190-L211)).

These designs show why OnePage needs a wire-event cap and fail-fast overflow. They do not justify a
maximum-sized array per call: both still make a complete token available to their caller, whereas
OnePage needs only a small projection of an open JSON envelope and already owns a streaming output
sink.

gRPC illustrates the advantage SSE lacks. Its five-byte message header reveals the payload length,
so grpc-go rejects an oversized message before reading its body and only then reads the declared
length
([source](https://github.com/grpc/grpc-go/blob/6d697e4b65eb0dcfaf326b5b1fcdc66913872442/rpc_util.go#L785-L808)).
It also applies the receive limit to decompressed output, reading at most one byte beyond the limit
to detect expansion
([source](https://github.com/grpc/grpc-go/blob/6d697e4b65eb0dcfaf326b5b1fcdc66913872442/rpc_util.go#L980-L1041)).
SSE has no advance length, so OnePage must count as it parses; the same principle still requires
independent wire-byte and decoded-byte limits.

### Proxies: backpressure is necessary, soft, and sometimes should spill

HTTP/2 explicitly defines its receive window as buffering capacity and says flow control exists to
protect memory-constrained endpoints; window credit is restored as bytes are consumed
([RFC 9113 section 5.2](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.2),
[section 6.9.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.9.1)).
Envoy's implementation documentation is more cautionary: buffer watermarks stop socket reads or
withhold HTTP/2 window updates, but all buffer limits are considered soft because bytes are already
in flight. For HTTP/1, stopping reads eventually pushes back through TCP
([Envoy flow control](https://github.com/envoyproxy/envoy/blob/9c085ba4a27fddea1811a8ecc98fc094dbdd455c/source/docs/flow_control.md)).

Therefore, exhausting a shared large-event slab pool would bound OnePage's heap, but not immediately
bound whole-machine memory. Ninety-two paused HTTP/1 connections can move the backlog into TLS,
socket, peer, and kernel buffers. A shared pool also introduces fairness and starvation policy that
an incremental parser does not need.

When complete logical content must survive but need not stay resident, nginx uses a small request
body buffer (8 or 16 KiB by default), writes overflow to a temporary file, and applies a separate
maximum body size
([official directives](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_buffer_size)).
That is the closer analogue for OnePage's exact candidate: stage decoded semantic bytes, not the raw
SSE event, and publish nothing until validation succeeds.

## Fundamental tension

The tension is not “streaming versus correctness.” It is between two different meanings of
completion:

- transport completion: the blank line says the SSE event is complete;
- semantic completion: JSON shape, discriminators, duplicate fields, decoded sizes, and the later
  terminal event say the candidate may become authoritative.

Buffering the whole event makes those boundaries coincide, but multiplies the largest legal wire
spelling by concurrency. Processing deltas avoids the final-item buffer, but makes ordering,
deduplication, and partial recovery part of OnePage's semantics. The better separation is to keep
final-item semantics while making validation transactional: parse now, stage bounded semantic bytes,
and commit only after the complete event and terminal status validate.

JSON object member order creates one subtle requirement. A large `arguments` or `text` field may
arrive before the enclosing `type`, `name`, or `role`. The projector must therefore be able to stage
a potentially relevant field provisionally; it must not assume provider member order. Unknown fields
can be syntax-checked and discarded without capture.

## Recommended OnePage shape

```text
HTTPS body reader
  -> 4 KiB per-call transfer window
  -> SSE projection Reader for one event + wire counters
  -> std.json.Reader.next(), depth bounded, unknown values skipped
  -> partial decoded string tokens
  -> bounded semantic validator + adapter-private decoded-value buffers
  -> event-end shape and duplicate-field validation
  -> terminal-event agreement
  -> existing model_protocol.write* + CandidateWriter
  -> Host settlement publishes; every other path aborts the transaction
```

JSON object order means an assistant-text value and a function-arguments value may both appear before
their discriminators prove which one matters. V1 therefore allows two adapter-private growable
buffers: assistant text capped by the existing 20 KiB semantic limit and exact tool arguments capped
at 98,316 bytes. Growth is clamped before allocation, unused capacity is reported, and both buffers
are released at terminal settlement. Their combined pathological occupancy is about 118 KiB, but
ordinary calls allocate only their actual decoded content rather than reserving that amount. The
same design can retain bounded input-request fields. None of this scratch is readable, durable, or
authoritative.

After validation the existing encoder already knows every length needed by the header, so it writes
the canonical header and replays the selected buffer into the append-only provisional capture.
SSE framing and JSON parsing remain inside the Codex adapter; the shared Provider seam and canonical
format do not change.

Do not assemble from delta events in V1. They may be ignored after their syntax and aggregate wire
budgets are charged. `output_item.done` remains the sole candidate source; `response.completed`
remains the settlement prerequisite.

## Limits supported by this architecture

| Resource | V1 limit | Consequence |
| --- | ---: | --- |
| HTTP response transfer window | 4 KiB per call | Fixed read-ahead; independent of event size. |
| Resident SSE/JSON scratch beyond the window | Small fixed parser state; target at most 4 KiB | No complete line, event, JSON string, or DOM. |
| Assistant text | Existing 20 KiB canonical envelope limit | Reject the entire candidate on overflow. |
| Bash command | Existing 2 KiB decoded value | Semantic limit, unchanged. |
| Patch | Existing 16 KiB decoded value | Semantic limit, unchanged. |
| Exact inner tool-arguments JSON | Existing 98,316 bytes | Preserve every currently accepted spelling in a capped growable buffer. |
| One SSE wire event | Existing 598,424 bytes counted | Work/compatibility bound, no same-sized allocation. |
| Complete SSE response | Existing 2,393,696 bytes counted | Aggregate work bound; no event-count limit needed. |
| Outer Codex JSON nesting | Existing depth 32 | Fixed parser stack; unknown members remain open-envelope compatible. |
| Strict inner tool JSON | Existing depth 32, 64 tokens, 32 members | Independent semantic-work limits while exact bytes stream to storage. |
| Assistant-text provisional buffer | Existing 20 KiB semantic bound | Allocated only with decoded content and released after settlement. |
| Tool-arguments provisional buffer | Existing 98,316-byte semantic bound | Allocated only with decoded content and released after settlement. |
| Canonical output staging | None beyond the writer window | Existing header-first encoder writes directly to `CandidateWriter`. |
| File-backed decoded spool | None in V1 | Add only if concurrency measurement rejects the in-memory occupancy. |
| Large-event RAM slab pool | None | Avoids shared starvation policy and kernel-buffer displacement. |
| Whole model call | Existing 300 seconds | Independent elapsed-work bound. |
| Concurrent model transports | At most 100, behind one Host permit count | Becomes a supported value only after the 1/10/50/100 measurement matrix. |

The 98,316-byte and 598,424-byte limits may be lowered later if OnePage deliberately stops accepting
pathological but legal double-escaped spellings. That decision should be based on captured Codex
traffic and written as a provider-compatibility rule. Lowering them to make resident memory look
smaller would hide the representation problem rather than solve it.

With the complete-event array removed, the fixed user-space byte storage is approximately the
existing 59,151-byte Zig HTTPS allocation plus a 4 KiB transfer window and small parser state per
connection. At 100 calls that is roughly 6-7 MiB before task stacks, structs, and allocator slack
(see the [transport budget](model-transport-memory-budget.md)). Decoded candidate buffers add actual
content occupancy; the pathological simultaneous text-plus-arguments case is about 118 KiB per call,
or about 11.5 MiB across 100 calls, before allocator slack. Backpressure and socket memory remain
whole-machine measurements, not consequences inferred from user-space array sizes.

## Bottom line

Ghostty's useful lesson is not its particular 2 KiB, 64 KiB, or four-buffer values. It is that
ordinary I/O uses a fixed owned working set, exceptional capture begins only for recognized
semantics, encoded bytes collapse into the next representation, overflow invalidates the whole
authoritative item, and full capacity stops the producer. Netty, gRPC, HTTP/2, Envoy, and nginx add
the complementary rules: cap every logical token, distinguish wire from decoded limits, treat
backpressure as soft whole-system control, and spill complete logical content when it must survive
but need not remain resident.

For OnePage, that means keeping final-event semantics and replacing complete-event capture with an
SSE projection reader, `std.json.Reader` partial tokens, two capped decoded-value buffers, and the
existing canonical writer. It removes the 598 KiB concurrency multiplier without inventing
delta-reassembly semantics, another storage lifecycle, or a new shared format.
