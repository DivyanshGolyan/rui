# DeepSeek Harness edit tools

Research date: 2026-09-09

Status: research comparison, not a OnePage contract. This note reports the
implementation and tests at one immutable DeepSeek Harness revision; it does
not select OnePage's edit architecture.

## Sources and pin

The local source was cloned from `https://github.com/deepseek-ai/deepseek-harness`
at commit [`b2e3b2a0125854567a4a5fcba75782e42fe84901`](https://github.com/deepseek-ai/deepseek-harness/tree/b2e3b2a0125854567a4a5fcba75782e42fe84901)
(`dsh-0.1.5-alpha.2`, commit date 2026-09-09). The pre-existing directory
`/tmp/onepage-agent-domain-priors-src/deepseek-harness` had source files but no
usable `HEAD` or `config`, so it was not used to assert a revision.

Primary source links below use that commit. Local line references are from the
detached research clone and identify the exact implementation inspected.

## Executive conclusion

DeepSeek has two edit surfaces:

1. `dsh-tool-fs` registers an `edit` tool with one file path, literal
   `old_string`, literal `new_string`, and optional `replace_all` (default
   false). It is the newer tool and calls a provider-level `ctx.fs.editText`.
2. `dsh-tool-str-replace-editor` registers `str_replace_editor`, a single
   command union containing `view`, `create`, `str_replace`, and `insert`. Its
   `str_replace` path reads the whole file and then calls `ctx.fs.writeText`.

Neither surface accepts a batch of edits, multiple files, explicit byte/line
ranges, or a separate expected-file-version field in the model-facing
schema. The old string itself supplies the text to locate and replace. The edit precondition is supplied out of band by the filesystem
observation policy: after a prior observation, the tool obtains a version
guard; without that policy, the provider is explicitly unconditional. No
explicit user approval or permission-wait record exists in these tool
implementations. Sandbox escalation is a separate per-call policy mechanism,
not a model of proposed edits awaiting approval.

The newer `edit` has a useful split for OnePage comparison: the call presenter
can show a proposed diff before execution, while the result presenter uses the
provider-returned before/after text to compute applied hunks with three lines
of context and stores that metadata for replay. This is presentation, not an
approval transaction. The provider performs one literal edit atomically under
a per-target lock, checks a supplied version before matching, stages and syncs
a complete replacement, then publishes it with rename. Cancellation is
best-effort before publication and does not provide a documented durable
mid-publication recovery protocol.

## Model-facing schemas and capabilities

### New `edit` tool

The schema is `file_path`, `old_string`, `new_string`, and optional
`replace_all`; sandbox escalation fields are added only when the mounted
filesystem is confining. `old_string` must be nonempty and differ from
`new_string`; empty `new_string` deletes the matched text. Default matching is
exactly one occurrence, while `replace_all: true` replaces every occurrence.
These constraints are enforced in `parseEditArgs`, before the filesystem
operation ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L17-L55), local `edit.ts:17-55`).

The tool resolves one path and performs one `ctx.fs.editText` call. It does not
accept a list of files or edits, a line range, a byte range, or a caller
provided file-version/hash field ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L84-L147), local `edit.ts:84-147`). The provider request has a boolean `replaceAll`, but still represents one search/replace request, not a batch ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs/src/types.ts#L146-L168), local `types.ts:146-168`).

The system-prompt guidance says to read first because the default observation
policy requires it, unless the file was just created or edited in the session
([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L75-L82), local `edit.ts:75-82`). The actual tool obtains the single-slot `fs/edit-intent` decision and passes its optional version to the provider; it does not call `stat` itself ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L113-L147), local `edit.ts:113-147`).

### Compatibility `str_replace_editor`

The command enum is `view`, `create`, `str_replace`, and `insert`. Paths must
be absolute. `view` supports a two-integer line range, with `-1` as the end
sentinel. `create` requires `file_text` and refuses an existing file.
`str_replace` requires nonempty `old_str`, permits omitted `new_str` as an
empty replacement, and `insert` takes a zero-based `insert_line` and text
([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-str-replace-editor/src/index.ts#L425-L498), local `index.ts:425-498`).

The compatibility editor has no `replace_all` field and rejects multiple
occurrences. It finds literal non-overlapping occurrences with
`indexOf(search, offset)` and requires exactly one; absence returns
`FS_EDIT_NOT_FOUND`, ambiguity returns `FS_AMBIGUOUS_EDIT`, and it reports
matching line numbers ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-str-replace-editor/src/index.ts#L43-L52), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-str-replace-editor/src/index.ts#L275-L327), local `index.ts:43-52,275-327`). It performs a full-file replacement through `writeText`; there is no multi-edit loop or explicit range application.

The two surfaces therefore differ materially: newer `edit` can deliberately
replace all matches and returns structured before/after content; the
compatibility editor is unique-match-only for `str_replace`, and its call-time
diff is only a presentation of the submitted old/new strings.

## Matching, normalization, and preconditions

The provider-level `editText` first checks that the target still exists and is
a regular file, then checks the optional expected version *before* reading or
matching. A stale guarded edit returns `FS_STALE_VERSION`, even if the old
string no longer exists in the changed file. With no expected version, the
provider edits the current file unconditionally ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/index.ts#L230-L263), local `index.ts:230-263`; [tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/tests/filesystem.spec.ts#L646-L721), local `filesystem.spec.ts:646-721`).

The local backend reads UTF-8 text, rejects NUL-containing or invalid UTF-8
files, normalizes CRLF to LF for matching, applies literal replacement, and
restores the detected dominant line-ending style on disk. The normalized
before/after strings returned for diffing are LF-based ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/fsio.ts#L655-L719), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/fsio.ts#L786-L819), local `fsio.ts:655-719,786-819`).

The observation policy is the read-before-edit precondition. Its event is a
single-slot waterfall: a listener returns `{ version }`, or the default yields
an unconditional edit. The policy records present/absent observations and
maps an unobserved existing target to `FS_NOT_OBSERVED`; it does not persist an
approval decision or an edit proposal ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/docs/subsystems/filesystem.md#L181-L185), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/docs/subsystems/filesystem.md#L461-L478), local `filesystem.md:181-185,461-478`). The compatibility editor exhibits the same behavior: with policy enabled, blind replacement is rejected until `view` observes the file; after observation it proceeds ([tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-str-replace-editor/tests/tools.spec.ts#L510-L548), local `tools.spec.ts:510-548`).

## Before permission, preview, and after permission

There is no explicit permission-wait state in either edit implementation. The
sequence is:

```text
tool call
  -> schema/value validation
  -> optional sandbox policy resolution
  -> path resolution
  -> observation-policy intent (version guard or unconditional)
  -> provider read/match/stage/publication
  -> observed-version event and result
```

For the newer `edit`, `presentCall` constructs a diff card from the submitted
path/old/new strings before execution. After success, `presentationMeta`
computes three-line-context hunks from the provider's before/after content;
`presentResult` uses those applied hunks and falls back to generic rendering on
errors or malformed replay metadata ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L94-L112), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L148-L167), local `edit.ts:94-112,148-167`). This is a preview/result display contract, not a permission gate. The diff algorithm produces one `FileDiff` per applied hunk with three context lines ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/diff.ts#L1-L56), local `diff.ts:1-56`).

The compatibility editor's `presentCall` shows a diff card for `create` and
`str_replace`, but `insert` has only a generic edit card; it does not preview
the actual affected lines. It has no result-time applied-hunk presenter
([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-str-replace-editor/src/index.ts#L376-L423), local `index.ts:376-423`).

Sandbox escalation is distinct from user approval. A confining filesystem adds
`sandbox_permissions` and `justification` fields and resolves a per-call
`SandboxExecutionPolicy`; a denial is mapped to `FS_SANDBOX_DENIED`. This
protects the filesystem boundary but does not save a proposed edit for later
approval ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/tool-fs/src/edit.ts#L84-L139), local `edit.ts:84-139`).

## Application scope, order, overlap, and atomicity

The newer provider operation is one request against one target. `replaceAll`
uses `content.split(oldNorm).join(newNorm)`, so all non-overlapping literal
matches are replaced in source order. There is no edit list, explicit overlap
resolution, or order between independent proposals ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/fsio.ts#L689-L817), local `fsio.ts:689-817`). The compatibility editor uses one `old_str` occurrence and constructs one whole-file string before writing; overlapping-match behavior is not exposed as a supported contract.

The local backend serializes mutations by resolved `targetKey`. Its comment and
tests establish that concurrent operations on one target are FIFO-ordered, so
one version-guarded operation wins and later operations with the old version
fail stale ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/index.ts#L71-L105), [tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/tests/filesystem.spec.ts#L742-L790), local `index.ts:71-105`, `filesystem.spec.ts:742-790`). This is per-target serialization, not a transaction spanning multiple files.

Publication writes the complete UTF-8 result to a private same-directory
staging directory, opens the temp file exclusively, syncs it, checks
cancellation, then renames it into place (or uses the Windows replacement
path). Failed pre-publication work attempts to clean the staging directory;
post-commit cleanup failure does not turn the committed write into failure
([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/fsio.ts#L556-L653), local `fsio.ts:556-653`). This supports whole-file publication atomicity for the local backend, but the inspected sources do not claim crash recovery, journaling, rollback, or durability across a machine/power failure. The `sync()` and rename sequence is implementation evidence, not a durable recovery guarantee.

## Cancellation and crash evidence

`editText` accepts an `AbortSignal`; local reads and staging writes translate
abort races to `FS_ABORTED`. `writeFileAtomic` checks the signal before setup,
before publication, and while writing the temp file. Therefore cancellation
before publication can leave the original target untouched, while cancellation
after publication cannot undo the edit. The tests cover pre-aborted edits and
mid-operation cancellation of the supporting read/write helpers, but do not
simulate a process crash at every publication boundary ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/src/fsio.ts#L571-L653), [tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/tests/fsio.spec.ts#L859-L879), [tests](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/fs/fs-local/tests/filesystem.spec.ts#L757-L764), local `fsio.ts:571-653`, `fsio.spec.ts:859-879`, `filesystem.spec.ts:757-764`).

The atomic-write tests use hooks to inspect staged files and force failures at
publication/cleanup boundaries. They establish cleanup and collision behavior
for the tested process, including guarded-create races, but they are not crash
tests: no test kills the process between `sync`, rename, and staging cleanup.
The source therefore supports the narrower statement “staged atomic local
publication with tested failure cleanup,” not “crash-resumable edit intent.”

## Evidence ledger for OnePage comparison

| Question | Observed DeepSeek behavior | Evidence strength |
| --- | --- | --- |
| Single or multiple edits? | One search/replace request per `edit`; compatibility tool one `str_replace`; no batch. | Schema and implementation |
| Multiple files? | No. Each call resolves one target and one target lock. | Schema, provider, tests |
| Explicit ranges? | No edit ranges. `view_range` and `insert_line` exist only on compatibility commands. | Schema and implementation |
| Exact matching? | Literal matching after CRLF-to-LF normalization; unique by default; optional replace-all on newer tool. | Provider and unit tests |
| Expected content/version? | Old string supplies the search text; policy supplies an optional opaque version guard. | Tool and policy docs |
| Before approval read/validation? | Argument/path/policy/observation checks occur before provider publication; no saved approval proposal. | Tool flow |
| Diff preview? | New `edit` call-time diff plus result-time applied hunks; compatibility call-time diff only for create/replace. | Presenter code |
| Overlap/order? | No batch overlap policy. `replaceAll` uses non-overlapping `split/join`; target mutations serialize. | Provider code/tests |
| Atomicity? | Full-file same-directory staging + sync + rename; one target at a time. | Local backend |
| Cancellation? | Abort before publication can prevent mutation; after publication is not reversible. | Source/tests |
| Crash recovery? | No durable edit journal or crash protocol found in inspected edit/fs sources. | Absence bounded to inspected source |

## Transferable lessons, without selecting OnePage architecture

* Keep proposal presentation separate from applied-result evidence. The newer
  tool's call-time snippet is useful to a UI, but only the provider's returned
  before/after basis describes what actually changed.
* If approval is required, it must be an explicit lifecycle outside this tool:
  the DeepSeek observation policy is a freshness guard, not an approval record.
* A version guard checked before matching avoids misleading “old text not found”
  errors against content that changed after the proposal was prepared.
* A per-target lock plus atomic whole-file publication gives a clear one-file
  race result. It says nothing about a group of files or about recovery after
  process death.
* Before promising crash-resumable edits, add evidence for the exact crash
  boundaries and a durable intent/outcome protocol. The inspected DeepSeek
  implementation does not provide that guarantee.
