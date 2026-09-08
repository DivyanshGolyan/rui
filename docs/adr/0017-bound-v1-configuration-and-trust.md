# Bound V1 configuration and trust established mechanisms

## Accepted resource-policy amendment — 8 September 2026

The [combined resource resolution](https://github.com/DivyanshGolyan/onepage/issues/89#issuecomment-5578432698) and [provider/tool policy](https://github.com/DivyanshGolyan/onepage/issues/91#issuecomment-5567420830) supersede the original public-configuration restrictions and pending Turn-budget choice below. There is no Turn-wide request allowance or deadline. Host startup configuration owns the selected execution, scratch, client, diagnostic, retry/inactivity, Bash-default and excerpt controls; Bash also permits its admitted per-call timeout. Internal derived workspaces and SQLite settings are not extra public knobs. [ARCHITECTURE.md](../../ARCHITECTURE.md#v1-limit-matrix) owns the accepted values and scope; Session configuration acknowledgements and supported mutable fields remain open in #101. [ADR-0027](0027-use-an-in-process-exact-edit-module.md) supersedes Git-backed editing.

## Accepted ownership amendment — 5 September 2026

[ADR-0020's ownership amendment](0020-version-model-visible-context-sparsely.md#accepted-ownership-amendment--5-september-2026) removes the separate Turn Contract. Current Session settings are selected independently at model request or Action admission, with exact historical inputs/permissions retained there. Permission Mode persists on the Session and may change; existing Authorizations are unchanged. Runtime information and retained resource limits stay with their actual consumers/scopes. Numeric limits remain with their assigned decisions. The older Turn-local settings and permission language below is historical where it conflicts with these amendments.

## Original decision

OnePage exposes a setting only when users repeatedly need the decision, one scope owns it, and the resolved value can be persisted and inspected. V1 has built-in defaults, one optional user configuration file, explicit CLI overrides, and explicit Turn arguments. Persistent model-visible defaults become sparse Session Context Revisions; one Turn Contract records the resolved source and value of every execution-affecting setting. Later ambient changes cannot alter admitted work, and an idempotent key with different bindings conflicts.

V1 publicly configures `active_capacity`; issue #91 decides whether the surviving Turn-wide provider-dispatch budget also warrants a user setting. A Turn may explicitly select model and reasoning effort. Provider endpoints, transport, buffers, retry classification and jitter, service metadata, and connection policy remain internal until evidence creates a recurring user decision. The configured local machine, SQLite, Git, libcurl, and OS credential store are trusted mechanisms within their documented contracts; OnePage validates syntax, resources, semantic conversion, and consequential effects rather than treating every dependency as hostile.
