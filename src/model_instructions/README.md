# Built-in instruction provenance

`luna.txt`, `terra-astra.txt`, and `sol.txt` contain modified OpenAI Codex instructions.
Rui copied the decoded `model_messages.instructions_template` values from `codex-rs/models-manager/models.json` at commit `ee344ca9458351a6ea102795fa73110ad3ede5dc` of `https://github.com/openai/codex`.
The reviewed stable tag `rust-v0.169.0` resolves to `d32063f96c2dff1dc96af839b3952abb6acfeda4` and contains the same four literal templates.
Terra and Astra have identical upstream bytes and share one modified asset.
The [third-party notices](../../THIRD_PARTY_NOTICES.md#openai-codex-instruction-text) retain the applicable copyright notice and full Apache 2.0 license in the installed distribution.

## Original bytes

| Exact model | Rui asset | Upstream UTF-8 bytes | Upstream SHA-256 |
| --- | --- | --- | --- |
| `gpt-6-luna` | `luna.txt` | 18043 | `b707476816bfe5e571a1bd2179f130fff2b132da5ab8e61063acdb7fd24daf12` |
| `gpt-6.1-terra` | `terra-astra.txt` | 21428 | `35bd51b5f577cb7b24cd5f4629e49e37cb724ab57754ce6f8f202001635bab8a` |
| `gpt-6.1-sol` | `sol.txt` | 21779 | `e1bdd4f8f0df4b20f4a0ffc8a861ce819df45325d8cecdfb92e80379cf8d142e` |
| `gpt-6-astra` | `terra-astra.txt` | 21428 | `35bd51b5f577cb7b24cd5f4629e49e37cb724ab57754ce6f8f202001635bab8a` |

Codex had published no template for `gpt-6.2-sol` or `gpt-6.2-astra` on 2026-11-17, when OpenAI released them.
Until it does, `gpt-6.2-sol` uses `sol.txt` and `gpt-6.2-astra` uses `terra-astra.txt`, the assets of their 6.1 and 6.0 predecessors.

## Rui modifications

[codex.patch](codex.patch) records every changed byte against the decoded originals.
It removes the opening identity paragraph because the shared Rui frame supplies identity and Workspace.
It removes the Codex name from the personality sentence.
It replaces unavailable asynchronous user-input and execution APIs with message and available-tool instructions.
It replaces the unavailable skill-discovery APIs with Rui's advertised skill tool or filesystem paths.
It removes unsupported skill aliases and catalog-location claims, retaining each skill's name, description, and filesystem path.
It replaces discretionary skill selection with a pointer to Rui's advertised catalog and invocation instructions.
It replaces the promise of verbatim user requests after compaction with guidance to continue from compacted context and retained history.
It removes the app and plugin execution sections because Rui does not supply that machinery.
It replaces test restrictions that conflict with user and repository verification requirements.
Other upstream wording, including model-specific differences and formatting, is retained.

## Reproduce the assets

Use an existing checkout of the pinned Codex commit.
Set `CODEX_SOURCE` to that checkout and run this block from the Rui repository root.
It extracts original UTF-8 bytes into a temporary directory, applies the checked-in patch, and compares every result.
The runtime performs no upstream fetch.

```sh
python3 - "$CODEX_SOURCE" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

repo = pathlib.Path.cwd()
source = pathlib.Path(sys.argv[1])
assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == "ee344ca9458351a6ea102795fa73110ad3ede5dc"
models = {model["slug"]: model["model_messages"]["instructions_template"] for model in json.loads((source / "codex-rs/models-manager/models.json").read_text())["models"] if model.get("model_messages") and model["model_messages"].get("instructions_template")}
assert models["gpt-6.1-terra"] == models["gpt-6-astra"]
names = {"luna": "gpt-6-luna", "terra-astra": "gpt-6.1-terra", "sol": "gpt-6.1-sol"}
with tempfile.TemporaryDirectory(prefix="rui-instructions-") as temporary:
    directory = pathlib.Path(temporary)
    for name, model in names.items():
        (directory / (name + ".txt")).write_bytes(models[model].encode("utf-8"))
    subprocess.run(["patch", "--batch", "-p1", "-i", str(repo / "src/model_instructions/codex.patch")], cwd=directory, check=True)
    for name in names:
        assert (directory / (name + ".txt")).read_bytes() == (repo / "src/model_instructions" / (name + ".txt")).read_bytes(), name
print("All built-in instruction assets match the pinned originals plus codex.patch")
PY
```
