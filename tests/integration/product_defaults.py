"""Read the values Rui's source owns, so fixtures follow the owner, not a copy.

DEFAULTS mirrors src/product_defaults.zig and CATALOG the generated
src/model_catalog_snapshot.zig. compaction_trigger and start_effort apply the
client's documented rules (src/client_defaults.zig, D111) to those values, so
a change to a default or a catalog row needs no fixture edit. The owners' own
tests pin the approved values; tests/ci/test_fixture_literals.py keeps
fixtures from restating them.
"""
import pathlib
import re
from types import SimpleNamespace

_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SOURCE = _ROOT / "src" / "product_defaults.zig"
_DECLARATION = re.compile(r'^pub const (\w+)(?:: \w+)? = (?:"([^"\\]*)"|(\d+));$', re.MULTILINE)
_TRIGGER = re.compile(r'\.provider = "(\w+)", \.tokens = (\d+)')
_ROW = re.compile(r'\.id = "((?:[^"\\]|\\.)*)", \.context_window = (null|\d+), '
                  r'\.efforts = \.init\(\.\{([^}]*)\}\), \.openai_listed = (true|false)')
# Rui's closed effort grammar, lowest first (src/model_catalog.zig).
EFFORTS = ("none", "low", "medium", "high", "xhigh", "max")


def _load():
    source = _SOURCE.read_text()
    values = {}
    for name, text, number in _DECLARATION.findall(source):
        values[name] = text if number == "" else int(number)
    triggers = source.split("pub const provider_compaction_triggers", 1)[1].split("};", 1)[0]
    values["provider_compaction_triggers"] = {provider: int(tokens) for provider, tokens in _TRIGGER.findall(triggers)}
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
    """The model's window from its row, else the unlisted default."""
    row = CATALOG.get(model)
    return row.context_window if row and row.context_window else DEFAULTS.unlisted_context_window


def compaction_trigger(provider, model):
    """The client's default trigger: the usual share of the model's window,
    capped by the provider's own default when it has one."""
    model_trigger = context_window(model) * DEFAULTS.compaction_trigger_percent // 100
    return min(DEFAULTS.provider_compaction_triggers.get(provider, model_trigger), model_trigger)


def start_effort(model, saved=None):
    """The effort a fresh Session on `model` starts at: the saved one, else the
    product default, when the model allows it; else its lowest listed effort."""
    row = CATALOG.get(model)
    for effort in (saved, DEFAULTS.reasoning_effort):
        if effort is not None and (row is None or effort in row.efforts):
            return effort
    return row.efforts[0] if row.efforts else None
