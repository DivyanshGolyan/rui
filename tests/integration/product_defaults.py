import pathlib
import re
from types import SimpleNamespace

_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SOURCE = _ROOT / "src" / "product_defaults.zig"
_DECLARATION = re.compile(r'^pub const (\w+)(?:: \w+)? = (?:"([^"\\]*)"|(\d+));$', re.MULTILINE)
_TRIGGER = re.compile(r'\.provider = "(\w+)", \.tokens = (\d+)')
_MODEL_TRIGGER = re.compile(r'\.provider = "(\w+)", \.model = "([^"\\]+)", \.tokens = (\d+)')
_ROW = re.compile(r'\.id = "((?:[^"\\]|\\.)*)", \.context_window = (null|\d+), '
                  r'\.efforts = \.init\(\.\{([^}]*)\}\), \.openai_listed = (true|false)')
EFFORTS = ("none", "low", "medium", "high", "xhigh", "max")


def _load():
    source = _SOURCE.read_text()
    values = {}
    for name, text, number in _DECLARATION.findall(source):
        values[name] = text if number == "" else int(number)
    triggers = source.split("pub const provider_compaction_triggers", 1)[1].split("};", 1)[0]
    values["provider_compaction_triggers"] = {provider: int(tokens) for provider, tokens in _TRIGGER.findall(triggers)}
    triggers = source.split("pub const model_compaction_triggers", 1)[1].split("};", 1)[0]
    values["model_compaction_triggers"] = {(provider, model): int(tokens)
                                           for provider, model, tokens in _MODEL_TRIGGER.findall(triggers)}
    catalog = (_ROOT / "src" / "built_in_tool.zig").read_text()
    names = re.search(r"pub const BuiltInTool = enum \{([^}]+)\};", catalog)
    assert names, "built-in tool catalog missing"
    values["tools"] = ",".join(name.strip() for name in names.group(1).split(","))
    declared = set(re.findall(r"^pub const (\w+)", source, re.MULTILINE))
    assert set(values) == declared, f"{_SOURCE}: teach this reader {sorted(declared - set(values))}"
    return SimpleNamespace(**values)


def _catalog():
    rows = {}
    for model, window, efforts, listed in _ROW.findall((_ROOT / "src/model_catalog_snapshot.zig").read_text()):
        marked = set(re.findall(r"\.(\w+) = true", efforts))
        rows[model] = SimpleNamespace(context_window=None if window == "null" else int(window),
                                      efforts=tuple(effort for effort in EFFORTS if effort in marked),
                                      openai_listed=listed == "true")
    assert rows, "src/model_catalog_snapshot.zig lists no models"
    return rows


DEFAULTS = _load()
CATALOG = _catalog()


def context_window(model):
    row = CATALOG.get(model)
    return row.context_window if row and row.context_window else DEFAULTS.unlisted_context_window


def compaction_trigger(provider, model):
    model_trigger = context_window(model) * DEFAULTS.compaction_trigger_percent // 100
    provider_trigger = DEFAULTS.provider_compaction_triggers.get(provider, model_trigger)
    return min(DEFAULTS.model_compaction_triggers.get((provider, model), provider_trigger), model_trigger)


def start_effort(model, saved=None):
    row = CATALOG.get(model)
    for effort in (saved, DEFAULTS.reasoning_effort):
        if effort is not None and (row is None or effort in row.efforts):
            return effort
    return row.efforts[0] if row.efforts else None
