# Built-in instruction provenance

`luna.txt`, `terra-astra.txt`, `sol.txt`, and `sol-astra-62.txt` contain modified OpenAI Codex instructions.
Rui copied the decoded `model_messages.instructions_template` values from `codex-rs/models-manager/models.json` at commit `8fca6ffb92a602875a0b97e3e535eb48375bdd8c` of `https://github.com/openai/codex`.
Terra and Astra have identical upstream bytes and share one modified asset. The 6.2 Sol and Astra templates also have identical upstream bytes and share an asset.
The [third-party notices](../../THIRD_PARTY_NOTICES.md#openai-codex-instruction-text) retain the applicable copyright notice and full Apache 2.0 license in the installed distribution.

## Original bytes

| Exact model | Rui asset | Upstream UTF-8 bytes | Upstream SHA-256 |
| --- | --- | --- | --- |
| `gpt-6-luna` | `luna.txt` | 17799 | `e52174f354e3970ad8de5935fff8d04ddf2890a35659283d163befb56490198c` |
| `gpt-6.1-terra` | `terra-astra.txt` | 21183 | `4ddce5803b638f01342f657002289d1307634c677df840eeefdd4bc5b451276d` |
| `gpt-6.1-sol` | `sol.txt` | 21534 | `d12e6dbdfd4a4ddb26a1f6048b69a32b8b32f74e4add9791d1dff7f4cac0b032` |
| `gpt-6-astra` | `terra-astra.txt` | 21183 | `4ddce5803b638f01342f657002289d1307634c677df840eeefdd4bc5b451276d` |
| `gpt-6.2-sol` | `sol-astra-62.txt` | 25959 | `aa47d2dee261594c4944241b646088730d74d87afa4da8d2da0554540a5e7623` |
| `gpt-6.2-astra` | `sol-astra-62.txt` | 25959 | `aa47d2dee261594c4944241b646088730d74d87afa4da8d2da0554540a5e7623` |

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

Use an existing checkout of the pinned Codex commit or an extracted copy of its `codex-rs/models-manager/models.json`.
Set `CODEX_SOURCE` to the checkout or JSON file and run this block from the Rui repository root. The script checks the original template hashes in either case.
It extracts original UTF-8 bytes into a temporary directory, applies the checked-in patch, and compares every result.
The runtime performs no upstream fetch.

```sh
python3 - "$CODEX_SOURCE" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

repo = pathlib.Path.cwd()
source = pathlib.Path(sys.argv[1])
if source.is_dir():
    assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == "8fca6ffb92a602875a0b97e3e535eb48375bdd8c"
    source = source / "codex-rs/models-manager/models.json"
models = {model["slug"]: model["model_messages"]["instructions_template"] for model in json.loads(source.read_text())["models"] if model.get("model_messages") and model["model_messages"].get("instructions_template")}
hashes = {
    "gpt-6-luna": "e52174f354e3970ad8de5935fff8d04ddf2890a35659283d163befb56490198c",
    "gpt-6.1-terra": "4ddce5803b638f01342f657002289d1307634c677df840eeefdd4bc5b451276d",
    "gpt-6-astra": "4ddce5803b638f01342f657002289d1307634c677df840eeefdd4bc5b451276d",
    "gpt-6.1-sol": "d12e6dbdfd4a4ddb26a1f6048b69a32b8b32f74e4add9791d1dff7f4cac0b032",
    "gpt-6.2-sol": "aa47d2dee261594c4944241b646088730d74d87afa4da8d2da0554540a5e7623",
    "gpt-6.2-astra": "aa47d2dee261594c4944241b646088730d74d87afa4da8d2da0554540a5e7623",
}
for model, expected in hashes.items():
    assert hashlib.sha256(models[model].encode("utf-8")).hexdigest() == expected, model
assert models["gpt-6.1-terra"] == models["gpt-6-astra"]
assert models["gpt-6.2-sol"] == models["gpt-6.2-astra"]
names = {"luna": "gpt-6-luna", "terra-astra": "gpt-6.1-terra", "sol": "gpt-6.1-sol", "sol-astra-62": "gpt-6.2-sol"}
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
