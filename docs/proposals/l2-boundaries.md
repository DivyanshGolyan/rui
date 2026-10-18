# Endpoint identity and configuration boundaries

Design proposals for Divyansh, based on main
[`cdad5aa`](https://github.com/DivyanshGolyan/rui/commit/cdad5aaf4dc43cbb7864f0fa0a4a08bf4f25a8ff). Neither proposal is implemented
by L2. The owning contracts remain in [Architecture](../../ARCHITECTURE.md).
The renderer owns CLI changes. Optional endpoint implementation requires a
separate capacity and file-ownership agreement with L2 before another writer starts.

## One protocol-owned endpoint definition

Endpoint identity appears in `protocol.Kind`, `server.Route`,
`server.HeaderReader.parseRoute`, and client request construction.
`client.MutationKind.route` repeats the five durable mutation paths.
Server-local `observe` and `inspect` translate to protocol kinds
`observe_command` and `inspect_session`. These are internal names, not two
accepted wire aliases. The final audit's endpoint finding is number 7.

Use one exhaustive compile-time definition in `protocol.zig`, keyed by
`protocol.Kind`. Each definition contains the exact HTTP method, path, request
kind, reply discriminator, and traffic class. Client request construction reads
that definition. Header classification resolves an exact method and path through
the same definition. Server handlers remain typed switches over request variants.
The table does not contain function pointers, Store access, or handler policy.

Unknown `/v1/control/` paths still need reserved Control classification before
body parsing. Represent that classification separately from known endpoints.
It has no request kind and cannot reach a typed handler. Do not turn an unknown
Control path into ordinary intake or infer Control from every request name.

The definition must distinguish durable mutation kinds from `host_stop`, which
targets a Host instance rather than a saved command. Body and streamed-content
reply framing remain with their existing owners. A shared path table must not
collapse those distinct response contracts.

This removes repeated endpoint identity without adding a generic command bus.
A macro that generates handlers would couple identity to execution and is not
needed. A server-only table would leave client paths as a second authority.

### Wire changes fail explicitly

The current wire marker is `protocol.wire_version = "1"`. Moving unchanged
identity data into one definition does not itself require a wire change. If
the chosen design changes paths, request tags, reply tags, or framing, bump the
marker and reject mismatched peers clearly before effects. Do not add old-path
aliases, dual decoders, or mixed-version client support. Wire compatibility is
not a requirement for this proposal, and the Store format need not change.

The acceptance cases need exact independent expected methods, paths, reply
tags, and Control classes for every current kind. A test that derives both
expected and actual values from the new table cannot catch a wrong table row.
Add missing-row and duplicate-path compile failures, exact-match versus prefix
lookalikes, unknown Control paths, and mismatch refusal before mutation.
Run the mapped native protocol/client/server gates and both installed-upgrade
jobs on the exact candidate. A format refusal is not a successful upgrade.

## Configuration parsing, defaults, and presentation have separate owners

`cli.configure` currently parses arguments, resolves fresh defaults, captures a
command, sends it, records admission, and presents the reply. Interactive
`/configure` separately recognizes flags and then rebuilds one-shot argv.
`cli_args.Command.session_configure` also describes the installed grammar.
The final audit's configuration finding is number 8. This proposal changes no
defaults, wire fields, or Store representation.

Parse installed argv and tokenized interactive input into the existing typed
configuration input plus capture options. Reuse `cli_args` option definitions
for syntax. Keep quoted interactive tokens borrowed only until capture copies
them. Express interactive restrictions as validation of that parsed input:
terminal stdin cannot supply instructions or schema content, and an attached
Session cannot change its destination through `/configure`.

Resolve only omitted fresh-Session fields at a composition boundary before
capture. `product_defaults.zig` remains the only product-default authority.
Preserve the just-landed values: Active and ordinary intake capacity 100,
tools `bash`, permission mode `bypass`, model `gpt-6-luna`, automatic compaction
at 90 percent of a known model window, and output reservation zero.
Explicit arguments and applicable saved preferences retain precedence.
An addressed update remains sparse, including an unknown addressed Session.
Omission preserves its settings. An explicit `default` policy argument resets
the override. No preliminary inspection decides whether configuration creates
or updates a Session.

The capture/send owner accepts the resolved typed input and never reparses
argv or prints terminal messages. It retains the exact command identity and
captured bytes through uncertain delivery. Admission comes from the framed
reply, never from successful output. Existing `writeMutationReply` and
`MutationPresentation` remain the presentation owner, including quiet successful
interactive Configure and contextual errors. Failure after accepted admission
must say that admission succeeded and must never construct a new request key.

Keep parsing independent of HOME, cwd, file capture, Host startup, and output.
Do not add a second default resolver or a generic command execution framework.
This boundary lets grammar tests exercise both invocation modes while native
tests still establish capture, delivery, recovery, and terminal restoration.

The acceptance cases need fresh versus addressed configuration, every omitted
provider/model combination, explicit versus saved defaults, unknown addresses,
quoted values, forbidden terminal stdin, `default` versus omitted policy,
capture failure, uncertain send, and presentation failure after admission.
Keep the original saved key and bytes through every delivery recovery case.
The renderer's current CLI and terminal fixtures remain read-only to L2.

## Source and implementation sequence

The actual final audit is [the audit thread](https://ampcode.com/threads/T-01a1500e-2a79-72ed-9be6-b9e1b1a69b57).
Its final numbering differs from earlier reports. The L2 implementation scope
comes from Divyansh's concrete instructions rather than that numbering.

The requested pstack principles were read from `cursor/plugins` at commit
[`0b8e952052d482ee6de06deebf14d590d77b1b34`](https://github.com/cursor/plugins/commit/0b8e952052d482ee6de06deebf14d590d77b1b34):

- `pstack/skills/principle-sequence-verifiable-units/SKILL.md`
- `pstack/skills/principle-fix-root-causes/SKILL.md`
- `pstack/skills/principle-prove-it-works/SKILL.md`

Those principles require independently checked units, correction at the first
wrong transition, and checks against the actual artifact. They do not authorize
rebasing this lane away from its exact requested base or changing reserved files.

The first L2 unit records production import dependencies reachable from the
`addRui` Zig root, excluding test declarations. The evaluator executable is
C-only. Its private Zig host adapter currently belongs to fixture coverage,
not the production import graph. At the requested base, 55 modules
contain three two-module strongly connected components: Store/provider output,
provider selection/model capability, and protocol/named scratch. This is literal
source-import evidence across platform branches, not compiler lazy-declaration
reachability. Store's test-only model-adapter imports do not form a production
cycle. `python3 tests/ci/import_architecture.py` reproduces the current graph.

The protocol/named-scratch unit moves inline bounded values below both owners
and imports ScratchBudget directly in named scratch. The capability unit needs
clean CLI caller migration and therefore remains pending renderer ownership
release. L2 adds no compatibility wrapper to work around that reservation.
