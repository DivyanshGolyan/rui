# Fixture-model Final Answer

## Question

Can the first user-visible OnePage command perform a durable model turn, release its execution page
while inference is pending, and reproduce the Final Answer after exact resume without letting the
provider adapter become the agent?

## End-to-end path

`onepage` verifies the compiled Wasm structure, resolves every product export, and executes a
non-durable semantic ABI smoke turn before creating state. This catches missing, mistyped, or
misbound exports before a Session identity can be published. Creation then allocates a durable
Session and immediately prints its stable 16-hex identity. The one-page core starts the Task, chooses
the root-to-leaf entry range for the model request, and submits one model Operation.
Session state defaults to `~/.onepage/sessions` rather than dirtying the target repository, and newly
created state and Session directories use owner-only permissions on the current macOS target.

The host walks that selected range one entry and one 4 KiB blob window at a time. It streams a
canonical request artifact to disk while computing its descriptor digest; it never creates a resident
transcript array. Before provider dispatch, an 80-byte accepted record durably names the Operation,
Attempt, ownership epoch, `billable_retry` recovery class, request digest, and journal sequence.

After the core accepts that Operation, its exact 64 KiB page is atomically checkpointed and the
JavaScriptCore instance is destroyed. The fixture provider then reads the same canonical request
artifact, verifies the expected task history, and writes a complete canonical response spool. It uses
the same bounded `Provider` contract reserved for the live adapter. The adapter receives only a
request-reader and predetermined response-writer capability—not the Session or its owner token—so it
cannot declare success, select a tool, mutate blobs outside that response, or append conversation
history.

A fresh JavaScriptCore instance restores the checkpoint. The response completion enters the ordinary
fixed-credit owner path, which persists the completed record before applying it. Application copies at
most 16 KiB into a reserved page window and asks the core parser to classify the complete response.
Only a complete, valid, non-empty text item with no tool call becomes a Final Answer candidate.

The host copies the core-selected text range to an immutable blob, appends an assistant Conversation
Entry, and only then lets the core commit the terminal Outcome. A final checkpoint makes exact resume
reproduce that same entry without dispatching another model Operation.

Finalization is replayable. If a process stops after the completed journal record, after the immutable
answer blob, or after the assistant entry but before the terminal checkpoint, resume reconciles the
journal and conversation against the accepted checkpoint. It reloads the already-spooled response,
verifies or recreates the deterministic answer blob, commits the same assistant entry, and publishes
the terminal page without another provider dispatch.

## Failure contract

The response artifact has a fixed binary envelope with explicit completion status and typed text or
tool items. The core rejects empty, length-truncated, aborted, provider-error, malformed, invalid-UTF-8,
and multiple-tool responses. None can create a Final Answer or authorize an effect. Parser tests cover
all structural classes, and the JavaScriptCore integration test proves a truncated fixture response
fails after durable completion without being shown as success. A provider returning without finishing
its response is rejected before a completed journal record is written.

## Bounds and current measurement

- core linear memory: exactly 65,536 bytes, initial and maximum;
- response window: at most 16 KiB inside that existing page;
- context and output windows: 4 KiB fixed host buffers;
- request blobs: at most 1 MiB on disk; canonical response spools: at most 16 KiB;
- checkpoint buffer: 65,600 bytes per active owner, outside the page;
- operation journal records: 80 bytes each;
- current ReleaseSmall core after the Bash continuation slice: 29 function exports and 154
  data-section bytes;
- model calls in this slice: exactly one for creation and zero for finished resume.

`zig build test -Doptimize=ReleaseSafe` runs the parser, bounded reconstruction, fixture-provider,
JavaScriptCore create/resume, three finalization crash boundaries, incompatible-ABI rejection before
Session publication, a real Git fixture, and negative truncation tests. `zig build fixture-answer
-Doptimize=ReleaseSmall` is the visible demonstration.
