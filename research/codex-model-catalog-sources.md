# Codex model catalog sources

Question: what does the first-party Codex CLI fetch as its model catalog, and which catalog facts can Rui treat as a definitive statement that a model is unavailable?

Inspected 2026-10-18 at two OpenAI Codex pins:

- **Current:** `main` at [`8c07694`](https://github.com/openai/codex/tree/8c076942cb70fba8e5c4732c23f1faabc4aed484) (committed 2026-10-18). The latest release then was `rust-v0.163.0`.
- **Rui's wire pin:** [`9688359`](https://github.com/openai/codex/tree/968835997714baaff199cfed5f89a2c65d8ca77d) (2026-09-10), the pin in [Provider wire contract](README.md#provider-wire-contract).

Both pins agree on every fact below unless a row says otherwise. Links use the current pin.

## Documented by source

| Fact | Source |
| --- | --- |
| The endpoint was introduced by [openai/codex#7603](https://github.com/openai/codex/pull/7603) (merged 2025-12-04, `903b777`). [#7616](https://github.com/openai/codex/pull/7616) (merged 2025-12-05, `7b359c9`) made the models manager call it with its auth manager. | PR metadata |
| The request is `GET {provider base}/models` with a `client_version=MAJOR.MINOR.PATCH` query parameter. For ChatGPT authentication the base is the same `https://chatgpt.com/backend-api/codex` base as `/responses`, with the same bearer-token provider. | [`endpoint/models.rs` L33-L46](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/codex-api/src/endpoint/models.rs#L33-L46), [test URL L547-L549](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/model-provider/src/models_endpoint.rs#L547-L549) |
| The response is `{"models":[ModelInfo...]}`. Each row requires `slug`, `visibility` (`list`, `hide` or `none`) and `supported_in_api`. Many other fields are optional or defaulted. | [`ModelsResponse` L850-L857](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/protocol/src/openai_models.rs#L850-L857), [`ModelInfo` L406-L423](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/protocol/src/openai_models.rs#L406-L423), [`ModelVisibility` L289-L298](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/protocol/src/openai_models.rs#L289-L298) |
| `visibility` controls only the picker: `show_in_picker = visibility == list`. | [L982](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/protocol/src/openai_models.rs#L982) |
| `supported_in_api` filters only API-key users. ChatGPT-authenticated users keep every row: `chatgpt_mode \|\| supported_in_api`. | [`filter_by_auth` L1025-L1030](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/protocol/src/openai_models.rs#L1025-L1030) |
| Codex dispatches hidden models. Its bundled catalog marks `codex-auto-review`, `gpt-daybreak-blue-latest` and `gpt-daybreak-red-latest` as `hide`, and a remote-model test requires a hidden model to remain listed but not shown in the picker. | [`models.json`](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/models-manager/models.json), [`remote_models.rs` L1320-L1366](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/core/tests/suite/remote_models.rs#L1320-L1366) |
| An explicit model choice is preserved without consulting the catalog. A slug missing from the catalog gets fallback metadata and a warning; it is not rejected. `visibility: none` is that synthesized fallback. | [`get_default_model` L200-L220](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/models-manager/src/manager.rs#L200-L220), [`model_info_from_slug` L97-L107](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/models-manager/src/model_info.rs#L97-L107) |
| Catalog metadata is not authority: "Discovery metadata does not grant access; inference still enforces authorization." | [`access_programs.rs` L1-L3](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/protocol/src/openai_models/access_programs.rs#L1-L3) (current pin only) |
| Refresh is bounded by a 5-second timeout. The on-disk cache TTL is 300 seconds. The in-memory catalog of a running process has no expiry. | [`MODELS_REFRESH_TIMEOUT` L44](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/model-provider/src/models_endpoint.rs#L44), [`DEFAULT_MODEL_CACHE_TTL` L35](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/models-manager/src/manager.rs#L35) |
| A 1 MiB body limit applies only to an explicitly configured custom catalog URL. The ChatGPT route has no client-side limit. The bundled catalog is 472,072 bytes with 11 rows. | [L47, L158-L162](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/model-provider/src/models_endpoint.rs#L158-L162) |
| Catalog identity is a digest of provider routing, account ID, user ID, plan and FedRAMP state. It excludes access tokens, so token rotation keeps the catalog. A fetched result is published only if the identity used for the request is still current. | [`models_identity.rs` L1-L61](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/model-provider/src/models_identity.rs#L1-L61), [`apply_remote_models` L683-L688](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/models-manager/src/manager.rs#L683-L688) |
| Source builds report `client_version` `0.0.0`. Release builds report the release version. | [`Cargo.toml`](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/Cargo.toml), [`client_version_to_whole`](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/models-manager/src/lib.rs#L19-L26) |

## Undocumented assumptions

OpenAI does not publish this endpoint. Rui depends on these assumptions, and each one fails open:

- The live route, response shape and field meanings match the inspected source.
- The server may filter rows by `client_version`, plan or account. A row missing for any of these reasons is not evidence that inference rejects the model.
- `hide` has no inference meaning beyond the picker. First-party code dispatches hidden slugs.
- The catalog stays well under 4 MiB and 256 rows. Larger responses fail open rather than being truncated.

## Conclusion and limits

No inspected field definitively states that inference will reject a slug for a ChatGPT-authenticated account. `supported_in_api` does not apply to this route, `hide` is picker presentation, and absence carries no rejection meaning. The first-party client never rejects an explicit model from catalog data.

These sources do not show live responses, account-specific rows, `client_version` filtering or the cause of any provider rejection. Rui's own `gpt-5-codex` HTTP 400 diagnosis is separate evidence. The bundled `models.json` at the current pin does not list `gpt-5-codex`.
