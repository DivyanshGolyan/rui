# Recent User Input Workload

Date: 2026-09-03

Status: local workload research for the User Input Wayfinder map. This is not a
normative limit or product contract.

## Question

How often does the user send another message while an agent is still working,
how large are those messages, and how many must the harness hold pending at
once?

## Answer

Active-turn User Input is a normal workload on this Mac, not an edge case. In
the seven-day sample, Claude Code natively classified 80 of 130 human CLI queue
submissions as absorbed during an active turn. Codex conservatively exposed 36
in-flight messages across 20 of 269 tasks.

The observed queue was shallow:

- Claude Code's human-input queue reached three submissions at once. At that
  depth the three messages totalled 518 bytes. The greatest human payload held
  in the queue at any sampled event was 8,862 bytes.
- Each of Claude Code's 80 active-turn human submissions was absorbed before a
  second active-turn human submission overlapped it. A turn could receive
  several sequential Steering Inputs, however: the observed maximum was four.
- Codex had at most one in-flight message between consecutive agent-output
  records. One task accumulated five such messages over its lifetime, totalling
  1,007 bytes.

This supports a durable SQLite input queue and small transient processing
memory. It does not support reserving a large per-agent input buffer. A pending
input should be a durable row plus bounded inline content or an immutable
content reference; the Host should load only the input it is admitting at the
next semantic boundary.

The sample does **not** justify freezing the final count or byte limits. It is
one user's seven-day workload, and only two local clients were observed.

## Sample and method

The rolling window was 2026-08-27 09:36 through 2026-09-03 09:36 IST
(2026-08-27T04:06:00Z through 2026-09-03T04:06:00Z).

The analysis read local JSONL transcripts without changing them. It used event
timestamps and structural fields, not message quotations. Subagent transcripts,
sidechains, meta messages, environment payloads, skill payloads, browser
context, and plugin declarations were excluded. No message text, session ID,
project path, or attachment path is reproduced here.

### Claude Code

Claude Code records every queued item as a `queue-operation`. The analysis:

1. selected top-level interactive CLI sessions;
2. paired `enqueue` and `remove` records by exact content in file order;
3. counted `remove` records whose reason was `absorbed_mid_turn`; and
4. excluded items with the native `task-notification` and
   `cross-session-message` envelopes.

That fourth step is essential. The same window contained 1,000 enqueued
cross-session agent messages and 525 enqueued task notifications. Of all 635
items marked `absorbed_mid_turn`, only 80 were untagged human submissions; 555
were orchestration traffic. Treating every queue item as User Input would
overstate the workload by almost eight times.

All 80 active-turn human submissions paired cleanly with their enqueue records.
They appeared in 23 top-level sessions and across 58 active turns. The full
interactive human-input denominator was 130 queue submissions, so the native
active-turn share was 61.5%.

### Codex

Codex does not expose a Claude-equivalent `absorbed_mid_turn` marker in these
rollouts. The analysis therefore used a conservative structural rule: a
top-level user-role payload counted as in-flight only when it appeared after
the task's first assistant message, reasoning item, or tool call and before its
terminal `task_complete` or `turn_aborted` event.

This found 36 in-flight messages among 331 ordinary user-role payloads (10.9%).
They occurred in 20 of 269 tasks (7.4%) across nine top-level sessions. The
method intentionally excludes messages submitted after task admission but
before the first agent-output record, because they cannot be distinguished
reliably from the initial admission bundle.

## Frequency and burst shape

| Measure | Claude Code | Codex |
| --- | ---: | ---: |
| All observed human inputs | 130 queue submissions | 331 ordinary user-role payloads |
| In-flight human inputs | 80 | 36 |
| Sessions containing in-flight input | 23 | 9 |
| Turns/tasks containing in-flight input | 58 turns | 20 tasks |
| In-flight inputs per affected turn/task, median | 1 | 1 |
| In-flight inputs per affected turn/task, P90 | 3 | 4 |
| Maximum over one turn/task | 4 | 5 |
| Maximum before another agent-output record | 1 | 1 |

The two percentages are not directly comparable. Claude Code supplies an
explicit queue disposition; the Codex result is a lower-bound inference over a
different event schema.

## Payload distribution

The table measures the text envelope in Unicode characters and UTF-8 bytes.
Referenced file or image bytes are not embedded in these values.

| Client and measure | P50 | P75 | P90 | P95 | P99 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Claude Code characters | 73 | 358 | 889 | 2,281 | 5,109 | 5,109 |
| Claude Code UTF-8 bytes | 73 | 360 | 895 | 2,289 | 5,142 | 5,142 |
| Codex characters | 70 | 118 | 309 | 337 | 842 | 842 |
| Codex UTF-8 bytes | 70 | 118 | 309 | 337 | 842 | 842 |

The Claude sample contained 33,263 bytes across 80 active-turn human inputs;
the Codex sample contained 4,183 bytes across 36. Each client had one
active-turn message with an attachment-reference marker. The referenced
content itself was not present in the message envelope and is therefore not
included in the byte distribution.

## Timing

Claude Code's queue records expose the interval from human submission until the
message was absorbed into the active turn:

| Percentile | Absorption delay |
| --- | ---: |
| P50 | 7.8 seconds |
| P75 | 21.6 seconds |
| P90 | 47.6 seconds |
| P95 | 104.5 seconds |
| P99 / maximum | 231.7 seconds |

The delay is long enough that a sleeping in-memory task would be wasteful and
short enough that polling SQLite at a modest cadence would not materially
change the user experience.

Codex does not expose an equivalent absorption boundary. Its in-flight messages
arrived a median 11.3 minutes after task start, with P90 at 34.4 minutes and a
maximum at 98.0 minutes. Those numbers describe how far into long-running work
the user intervened; they are not queue dwell times.

## Relationship to correction, questions, status, and cancellation

A conservative keyword classifier was run over the candidate human messages.
Labels overlap, so these counts must not be added together.

| Structural class | Claude Code, out of 80 | Codex, out of 36 |
| --- | ---: | ---: |
| Question or clarification | 29 | 16 |
| Correction or added constraint | 17 | 8 |
| Status/progress query | 4 | 0 |
| Explicit stop/cancel/pause wording | 0 | 2 |

Four Codex tasks with in-flight messages later ended in `turn_aborted`, out of
20 affected tasks. Event order alone does not establish that the message caused
the abort. Claude Code also recorded four human queue removals without the
`absorbed_mid_turn` reason; they were excluded from the active-input count.

The useful architectural distinction is qualitative: questions, corrections,
and added constraints are substantially more common than explicit
cancellation. Ordinary Steering Input should therefore not be implemented as
implicit cancellation. Cancellation remains a separate, explicit operation.

## Implications for the User Input map

1. **Steering is required V1 behavior.** Rejecting all User Input while a Turn
   is active would reject a common observed interaction, especially in the
   long-running Claude Code workload.
2. **SQLite can own the wait.** Observed absorption delays reach minutes, while
   only one human input was normally pending at a time. No resident queue,
   sleeping retry object, or preallocated per-agent message buffer is justified.
3. **Order must be durable.** A Turn can receive several sequential Steering
   Inputs even though simultaneous queue depth is low. Arrival ordinal,
   idempotency identity, and application boundary belong in SQLite.
4. **Keep orchestration traffic out of User Input.** Task notifications and
   cross-session agent messages outnumbered human Claude queue submissions by
   more than eleven to one. They need their own provenance and admission
   policy; they must not consume the human Steering Input budget accidentally.
5. **Use references for exceptional content.** The observed active text tail is
   measured in kilobytes, not hundreds of kilobytes, and attachment bytes were
   already represented indirectly. A later limit decision should distinguish a
   small inline envelope from immutable referenced content.
6. **Do not infer cancel from prose arrival.** Most interventions refine or ask
   about ongoing work. Explicit cancellation should be typed separately, and
   commit order should decide the race with an Operation boundary.

## Limitations

- This is one person's activity on one Mac over seven days. It is useful for a
  realistic local shape, not a population percentile or denial-of-service
  bound.
- The clients use different schemas. Claude Code's active-turn classification
  is native; Codex's is conservative and may undercount early steering.
- The text classifier is heuristic. It establishes broad proportions but does
  not prove semantic intent, and overlapping labels are intentional.
- Transcript timestamps measure recorded events, not keystrokes, network
  arrival, SQLite admission, or model-context visibility.
- Queue snapshots are reconstructed from persisted queue operations. Very brief
  states absent from the log cannot be measured.
- File and image contents are referenced rather than embedded, so the byte
  table is an envelope distribution, not a total content-size distribution.
- Automated and internal records were removed using currently observed native
  envelopes. A future client format could require new filters.

## Resolution proposed for the research ticket

Record active-turn User Input as common but shallow: durable Steering Inputs
must be supported, SQLite should own their ordering and wait, and the Host
should not reserve message buffers per active agent. Carry the observed maxima
(three simultaneously queued human submissions and 8.9 KiB at one queue
snapshot) into the admission-bound decision as workload evidence, not as the
limits themselves. Keep cancellation and orchestration messages separate from
ordinary Steering Input.
