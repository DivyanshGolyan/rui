# Developer-tool configuration practices for OnePage V1

Research date: 2026-08-29

OnePage revision examined: `10c461f01165389acd23453ee1b820e123606f55`

## Verdict

OnePage should be configurable, but it should not ship a general-purpose configuration system in V1.
The useful common pattern across Codex, Git, Cargo, and ripgrep is not their number of knobs or their
exact precedence ladders. It is this:

> Give omission a good meaning, put each decision at the narrowest scope that owns it, let an explicit
> invocation choice beat a persistent default, keep secrets elsewhere, and make the resolved choice
> inspectable and reproducible.

For OnePage, that implies three owners with deliberately different surfaces:

- the **Host** owns physical capacity and machine-wide resource policy;
- the **Run** owns retry policy and snapshots it when the Run is created;
- each **Job** owns the model contract choices that can intentionally vary between workflow steps.

V1 should have one optional user-level TOML file, dedicated CLI flags for the two settings that need
one-off overrides, and two optional fields on `agent()`. It should have no project config discovery,
environment-variable mirror, generic `--config key=value`, user-defined profiles, provider option bag,
or secret-valued configuration.

This is consistent with OnePage's existing contract. V1 already promises one startup-fixed ordinary
capacity setting, one built-in Workflow Resource Profile, one built-in Agent Profile, a fixed exact
Job specification, and no provider registry or user-tuned resource graph
([product contract](../../PRODUCT.md), [simplicity ADR](../adr/0010-make-simplicity-a-v1-requirement.md)).
The recommendation below changes none of those normative documents; it describes the smallest
configuration surface that can support the open Codex decisions.

## Evidence from mature tools

### Useful defaults and explicit overrides

Codex resolves dedicated CLI flags and `--config` overrides above trusted project config, a selected
profile, user config, system config, and built-in defaults. Its own guidance says to keep profiles
focused on values that differ from shared defaults
([Codex precedence](https://developers.openai.com/codex/config-basic#configuration-precedence)). Cargo
similarly makes `--config` override environment variables, which override configuration files
([Cargo command-line overrides](https://doc.rust-lang.org/cargo/reference/config.html#command-line-overrides)).
Git's runtime configuration environment overrides files and is itself overridden by explicit `git -c`
options
([Git environment precedence](https://git-scm.com/docs/git-config#Documentation/git-config.txt-GITCONFIGCOUNT)).
ripgrep implements the same user expectation with less machinery: it prepends configured arguments,
so later explicit CLI arguments normally win
([ripgrep configuration](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md#configuration-file)).

The reusable rule is **explicit intent now beats a stored default**. The exact ladders are products of
each tool's history and deployment model. OnePage does not need six layers merely because Codex has six.

### Scopes are ownership and trust boundaries

Git names system, global, repository, worktree, and command scopes. More importantly, it honors some
security-sensitive settings only in protected system, global, or command scope so an untrusted
repository cannot choose them
([Git scopes](https://git-scm.com/docs/git-config#SCOPES)). Codex likewise loads project configuration
only for trusted projects and refuses project-local overrides for provider, authentication, host-owned
request metadata, notification, and telemetry settings
([Codex project config](https://developers.openai.com/codex/config-advanced#project-config-files-codexconfigtoml)).
Cargo merges personal and directory-local configuration, with the closest directory winning for scalar
values
([Cargo hierarchy](https://doc.rust-lang.org/cargo/reference/config.html#hierarchical-structure)).

The common rule is **a value should be legal only where its owner and trust boundary make sense**.
OnePage therefore should not let an untrusted workflow choose Host capacity, credentials, transport,
headers, endpoint, or retry classification merely because those values could be represented in JSON.

### Reproducible behavior is committed or snapshotted

Cargo explicitly recommends putting dependency patches in checked-in `Cargo.toml` rather than normally
uncommitted Cargo config so another developer can reproduce the build
([Cargo patch guidance](https://doc.rust-lang.org/cargo/reference/config.html#patch)). OnePage's equivalent
is stronger because Runs are durable: all execution-affecting defaults must be resolved and stored when
the Run or Job is created. Editing user configuration later must not change an existing Run, a Job's
identity, or replacement Attempts under one model Operation.

This follows OnePage's existing requirement that every Run bind its exact workflow, arguments,
Workspace, semantics, resource profile, and keyed Job specifications
([product contract](../../PRODUCT.md)). It also preserves the existing rule that every replacement Attempt
under one model Operation dispatches the same model contract
([model-tool contract ADR](../adr/0012-separate-model-tool-contracts-from-execution.md)).

### Secrets are not normal configuration

Codex can keep cached login credentials in an OS credential store, warns that its file-backed cache
contains access tokens, and refreshes ChatGPT tokens during use
([Codex credential storage](https://developers.openai.com/codex/auth#credential-storage)). Cargo stores
sensitive values in a separate credentials file and supports credential providers
([Cargo credentials](https://doc.rust-lang.org/cargo/reference/config.html#credentials)). Codex's custom
provider reference discourages a literal bearer token and instead supports credential indirection
([Codex provider fields](https://developers.openai.com/codex/config-reference#model_providersid)).

OnePage's macOS Keychain decision is therefore the complete V1 configuration story for credentials.
Tokens, refresh tokens, account identifiers, arbitrary authorization headers, and credential environment
variables must not be accepted in the workflow, user TOML, Run snapshot, transcript, or CLI arguments.

### Effective configuration should be observable

Git can show both the origin and scope of every configuration value
([`--show-origin` and `--show-scope`](https://git-scm.com/docs/git-config#Documentation/git-config.txt---show-origin)).
ripgrep exposes the loaded configuration through debug output and provides `--no-config` for a clean
invocation
([ripgrep configuration diagnostics](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md#configuration-file)).

OnePage need not copy those commands, but `inspect` should expose the resolved, durable Run and Job
values. Reporting only the source file is insufficient: a resumed Run must show what it captured, not
what the file says today.

### Profiles are bundles for recurring modes, not a substitute for defaults

Codex profiles are explicitly selected layers intended to contain only differences from the user's base
configuration
([Codex profiles](https://developers.openai.com/codex/config-advanced#profiles)). Cargo's named profiles
bundle coherent build modes and custom profiles inherit from an existing profile
([Cargo profiles](https://doc.rust-lang.org/cargo/reference/profiles.html)).

OnePage has no demonstrated recurring mode such as `cheap-batch` or `urgent-review` yet. Its existing
named `default` Agent Profile and Workflow Resource Profile are immutable product contracts, not a user
configuration framework. V1 should not add user-defined profiles until multiple fields repeatedly need
to move together and a named bundle is clearer than two explicit values.

### Extension behavior reflects compatibility obligations

Git configuration is an extension namespace shared by Git and adjacent tools; Git documents that other
tools may define their own variables. That makes tolerance of unknown values useful for its ecosystem
([Git configuration file](https://git-scm.com/docs/git-config#_configuration_file)). Codex publishes a
closed configuration schema and reserves built-in provider identifiers even while allowing documented
custom-provider records
([Codex config source](https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs),
[Codex provider reference](https://developers.openai.com/codex/config-reference#model_providersid)).

OnePage V1 has no third-party configuration namespace or backward-compatibility promise. Silent unknown
keys would therefore hide misspellings without enabling a real extension. Every unknown key, wrong
type, duplicate key, out-of-range value, and illegal scope should fail before Run or Job creation with
the exact path and allowed alternatives.

## Common principles versus tool-specific accidents

| Observation | Common principle to adopt | Accident not to copy |
| --- | --- | --- |
| Codex, Cargo, Git, and ripgrep all let explicit invocation choices win | A one-off explicit choice beats a persistent default | A universal six-layer precedence ladder |
| Git and Codex restrict settings by scope and trust | Put a value only where its owner can safely accept it | Git's system/global/local/worktree complexity |
| Cargo separates reproducible manifest facts from personal config | Snapshot execution-affecting values | Cargo's array concatenation and recursive includes |
| Codex and Cargo separate credentials | Keep secrets in Keychain and out of ordinary config | Provider environment keys and command-backed auth needed by multi-provider tools |
| Git and ripgrep can explain loaded configuration | Show resolved values and provenance | A separate configuration debugger before one is needed |
| Codex and Cargo support named profiles | Add a profile only for a recurring coherent mode | User-defined Agent/Run profile frameworks in V1 |
| Codex exposes typed provider fields | Keep provider mechanics inside the adapter | Arbitrary headers, query parameters, endpoints, payload hooks, and transport selection |
| GitHub Actions places concurrency at workflow/job scheduling scopes | Put resource limits at the owner of the shared resource | Its organization/repository/environment/workflow/job/step variable hierarchy ([Actions variables](https://docs.github.com/en/actions/reference/workflows-and-actions/variables#configuration-variable-precedence)) |

ripgrep's one-argument-per-line file is an excellent design for a flag-oriented search tool, including
its simple override behavior and `--no-config` escape hatch. It is not a suitable syntax for OnePage's
typed, durably snapshotted Run policy
([ripgrep configuration format](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md#configuration-file)).

## Recommended OnePage V1 model

### 1. One small optional user file

Load one optional user-owned TOML file from one documented macOS location. Do not walk parent
directories, load repository files, process includes, interpolate environment variables, or merge
multiple files. The exact platform path is an implementation decision, but it must not be the project
Workspace and the Host must report which path it loaded.

The entire V1 schema should be:

```toml
[host]
active_capacity = 100 # illustrative; release default remains measurement-driven

[run]
model_retries = 3
```

`active_capacity` already exists as OnePage's one ordinary startup-fixed resource setting. Its default
must be the release-tested safe value; the target of 100 concurrent active agents is verification
evidence, not a reason to hard-code 100 before measurement. `model_retries` means replacement Attempts
after the initial Attempt. `0` disables automatic replacement; no separate `retries_enabled` Boolean is
needed. V1 should bound the value, with the final maximum justified by cost, duration, and recovery
tests. The Pi-compatible default discussed for OnePage is `3`, yielding at most four total Attempts.

The backoff sequence, jitter, retryable failure classification, `Retry-After` cap, authentication refresh
limit, and transport cleanup are implementation policy. They should be documented and tested, but not
independent knobs. Cargo's single `net.retry` value is useful precedent for exposing an outcome-oriented
limit rather than its entire retry algorithm
([Cargo network settings](https://doc.rust-lang.org/cargo/reference/config.html#netretry)). Codex exposes
separate HTTP and stream retry counts inside a general custom-provider system; that is provider-library
breadth, not evidence that OnePage workflows need both
([Codex retry fields](https://developers.openai.com/codex/config-reference#model_providersidrequest_max_retries)).

### 2. Dedicated explicit overrides, not a generic override language

Allow only dedicated one-off flags:

```text
onepage --active-capacity N ...
onepage run ... --model-retries N
```

`--active-capacity` is a Host-startup override and affects current physical admission only.
`--model-retries` is legal only while creating a new Run; the resolved value is stored in that Run.
Reattaching with the same Run Key does not reinterpret the current flag or user file. If a repeated
creation supplies a conflicting value, it fails as a binding conflict rather than silently changing the
Run.

Do not add `--config key=value`, `ONEPAGE_*` mirrors, an alternate config path, or a `--no-config` mode
in V1. Those features create precedence and testing surfaces larger than the two settings they serve.
A deterministic test can supply an isolated user-data directory or construct the typed configuration
input below the CLI boundary without making environment variables part of the product contract.

### 3. Two optional per-Job semantic choices

Extend the durable intrinsic only with:

```js
agent({
  key,
  task,
  input,
  schema,
  agent_profile,
  model,
  reasoning_effort,
})
```

`model` is an optional bounded model-name string. `reasoning_effort` is an optional closed enum supported
by the Codex adapter. Omission uses the adapter's tested provider default; the exact resolved values are
stored in the immutable Job specification before its first model Attempt. An unknown model becomes a
typed provider rejection; an unknown reasoning value or illegal model/effort combination fails before
dispatch.

This matches the useful part of Codex's design: model and reasoning effort have defaults, while explicit
launch choices can override them
([Codex model and reasoning fields](https://developers.openai.com/codex/config-reference#model_reasoning_effort)).
It also matches the workflow need: different steps may deliberately trade latency and reasoning quality.
Neither field grants permission, changes Host capacity, selects a provider, or changes the Tool Catalog.

### 4. Keep service tier out of V1

Codex exposes service tier as a preferred routing choice for new turns and treats it independently from
model and reasoning defaults
([Codex service tier](https://developers.openai.com/codex/config-reference#service_tier)). That proves the
concept can vary; it does not prove OnePage users have a recurring decision to make. The direct
ChatGPT-subscription adapter must first establish which tiers the endpoint actually accepts and what
cost or latency contract they imply.

V1 should therefore use the adapter's tested default and expose no `service_tier`. If evidence later
shows a real choice, add one closed Run-level policy first. Do not put it on every Job until workflows
demonstrate a need to mix tiers within one Run.

### 5. Keep concurrency solely Host-owned

`active_capacity` remains the only public concurrency setting. Provider connection limits, HTTP idle
pool size, semantic-admission permits, effect permits, SQLite ownership, and evaluator capacity stay
private and measurement-driven. They may be separately instrumented without becoming configuration.
This directly follows OnePage's rule to keep private stage permits out of public configuration until a
product consumer needs them
([engineering style](../style.md)).

The goal of 100 simultaneous active agents should be a release benchmark and support claim. It should
not create `max_active_agents` per Run or per Job: multiple Runs share one Host, so a Run cannot safely
redefine the Host's physical budget. GitHub Actions' ability to set concurrency at workflow and job
levels serves independently scheduled remote jobs; it is not OnePage's ownership model
([Actions concurrency](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)).

### 6. No provider passthrough

V1 must not accept any of the following:

- `provider_options` or an arbitrary JSON/TOML map;
- endpoint, transport, header, query-parameter, or raw request overrides;
- provider selection or fallback;
- separate HTTP and SSE retry policies;
- temperature, top-p, verbosity, reasoning-summary, or arbitrary sampling values;
- secrets or names of environment variables containing secrets.

The provider adapter owns its truthful identity, endpoint, browser authorization, Keychain access,
request lowering, SSE parsing, and typed error mapping. A future second provider may justify a typed
provider-neutral field or a private adapter configuration seam. It does not justify an escape hatch now.

## Exact precedence and snapshot rules

There is no universal precedence ladder. Each value has one short path:

| Value | Resolution, highest precedence first | Durable behavior |
| --- | --- | --- |
| `active_capacity` | dedicated CLI flag, user file, built-in | Startup-fixed Host fact; never a Run or Job binding |
| `model_retries` | `run` CLI flag, user file, built-in `3` | Resolved once and stored in the new Run; later config edits do not apply |
| `model` | explicit `agent()` field, tested Codex adapter default | Resolved exact model stored in immutable Job identity |
| `reasoning_effort` | explicit `agent()` field, tested model/provider default | Resolved exact effort stored in immutable Job identity |
| credentials | Keychain only | Loaded/refreshed by Host auth; never copied into Run or Job state |
| service tier | adapter default only | Store provider evidence if needed; no V1 user choice |

`inspect` should expose at least the Run's resolved retry limit and each Job's resolved model and reasoning
effort. It should distinguish an explicit value from a default without retaining secrets or mutable file
contents. Replacement model Attempts remain operational ledger facts outside Conversation; retry count
never becomes model-visible transcript text.

## Testable simplicity budget

The following limits make the philosophy falsifiable for V1:

| Dimension | V1 budget |
| --- | ---: |
| Automatically loaded config files | 1 user-owned file |
| Public config scopes | 3 owners: Host, Run, Job |
| User-file keys | 2: `active_capacity`, `model_retries` |
| Dedicated configuration CLI flags | 2 matching those keys |
| Optional Job model-control fields | 2: `model`, `reasoning_effort` |
| Environment-variable configuration keys | 0 |
| Project/workspace config layers | 0 |
| User-defined profiles | 0 |
| Generic key/value or passthrough maps | 0 |
| Configurable retry algorithm components | 1: retry limit only |
| Configurable concurrency controls | 1: Host `active_capacity` only |
| Secret-valued config fields | 0 |
| Boolean config keys in this model | 0 |
| Unknown keys silently ignored | 0 |

Tests should prove:

1. omission selects the documented built-in value;
2. each dedicated explicit override beats its one persistent default;
3. an existing Run and Job remain unchanged after the user file changes;
4. conflicting Run reattachment fails closed;
5. unknown, duplicate, misplaced, malformed, and out-of-range values fail with a path-specific error;
6. inspection reports each resolved non-secret value and its source class;
7. credentials never appear in parsed configuration, durable snapshots, logs, diagnostics, transcripts,
   child environments, or workflow values;
8. retries create durable Attempts without adding Conversation entries;
9. only `active_capacity` changes Host admission, and no private pool setting is externally reachable;
10. the provider receives no arbitrary caller-controlled header, endpoint, transport, or request field.

Any proposed additional knob should answer all of these before acceptance:

- What recurring user decision cannot be served by the existing default?
- Which single owner—Host, Run, or Job—owns it?
- Is it semantic and therefore snapshotted, operational and therefore Host-owned, or secret and therefore
  excluded from configuration?
- What is its closed type and explicit bound?
- How is the resolved value inspected?
- Which existing setting or internal policy can be removed instead?
- What release evidence shows that adding it is simpler for users than retaining one tested default?

If those answers are absent, the value remains an internal policy. This is the practical guard against
Boolean and configuration explosion.

## Evolution and versioning

Do not add a public `config_version = 1` before incompatible user-file formats exist. Keep the V1 parser
closed and typed, add keys only when they pass the budget above, and prefer a clear startup error over a
silent guess. Because OnePage is pre-release and its current contract explicitly grants no migration
promise for internal formats, it should not accumulate deprecated aliases merely to simulate maturity
([product exclusions](../../PRODUCT.md)).

The durable resolved Run and Job records are different: their codec and semantic identity must remain
explicitly versioned because crash recovery reopens them after the source defaults have changed. A
future rename in user TOML may have a deliberate migration message, but it must resolve to the same
versioned durable field before a Run begins.

## Decision summary

Adopt now:

1. provider/model defaults that make omission useful;
2. optional per-Job `model` and `reasoning_effort`, resolved and snapshotted;
3. one bounded Run-level `model_retries` setting, defaulting to three retries, with internal backoff and
   failure classification;
4. one Host-level `active_capacity`, with a measurement-driven default and a 100-active-agent release
   benchmark;
5. one optional user file and one dedicated CLI override for each of those Host/Run settings;
6. Keychain-only credentials, strict unknown-key rejection, and effective-value inspection.

Defer:

- service tier until the subscription endpoint and a user-facing latency/cost decision are proven;
- user-defined profiles until several settings repeatedly form a coherent named mode;
- every project config, environment mirror, generic override, provider passthrough, and private pool
  setting.

This gives users control over the four decisions they genuinely make—capacity, retry tolerance, model,
and reasoning effort—without turning the OnePage workflow API into a mirror of Codex's transport or the
Host into a configuration framework.
