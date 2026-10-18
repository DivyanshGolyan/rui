"""Read src/product_defaults.zig so fixtures follow the module, not a copy.

Each fixture still pins the current product values it depends on through its
own assertions; this only removes duplicate expectations of one source.
"""
import pathlib
import re
from types import SimpleNamespace

_SOURCE = pathlib.Path(__file__).resolve().parents[2] / "src" / "product_defaults.zig"
_DECLARATION = re.compile(r'^pub const (\w+)(?:: \w+)? = (?:"([^"\\]*)"|(\d+));$', re.MULTILINE)


def _load():
    values = {}
    for name, text, number in _DECLARATION.findall(_SOURCE.read_text()):
        values[name] = text if number == "" else int(number)
    expected = {"active_capacity", "intake_capacity", "tools", "permission_mode", "recommended_model",
                "compaction_trigger_percent", "output_reservation"}
    assert set(values) == expected, f"{_SOURCE} declarations changed: {sorted(values)}"
    return SimpleNamespace(**values)


DEFAULTS = _load()
