import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src"

PROVIDER_OWNED = (
    "codecs/*",
    "codex_*.zig",
    "chatgpt_*.zig",
    "providers.zig",
    "provider_name.zig",
    "api_key.zig",
    "provider_login.zig",
    "host_start.zig",
    "SignIn.zig",
    "model_list.zig",
    "model_capability.zig",
    "cli.zig",
    "cli_args.zig",
    "tests.zig",
    "logic_tests.zig",
    "testing/*",
)

RULES = (
    ("imports a sign-in file", re.compile(r'@import\("codex_')),
    ("names a ChatGPT or Codex header", re.compile(r"chatgpt-account-id|x-openai-|x-codex-", re.IGNORECASE)),
    ("names an OpenAI error code", re.compile(
        r"\b(?:insufficient_quota|credit_balance_exhausted|organization_spend_limit_exceeded|"
        r"project_spend_limit_exceeded|usage_limit_reached|usage_not_included|cyber_policy|bio_policy|"
        r"misalignment_policy_violation|invalid_prompt|model_not_found|refresh_token_expired|"
        r"refresh_token_reused|refresh_token_invalidated)\b")),
    ("names a ChatGPT endpoint", re.compile(r"chatgpt\.com")),
    ("switches on a provider", re.compile(r"\bProvider\.(?:codex|openai|chatgpt)\b|\.(?:codex|openai|chatgpt)\s*=>")),
)

CODEC_RULES = (
    ("reads the model name", re.compile(r"\bmodelName\(")),
    ("names a model", re.compile(r'(?:"|\\\\)(?:gpt|o\d|codex)[-\w.]*(?:"|$)', re.IGNORECASE | re.MULTILINE)),
)

ALLOWED = {
    ("provider.zig", "names a ChatGPT or Codex header"),
    ("store/sqlite_tests.zig", "switches on a provider"),
}

TEST_BLOCK = re.compile(r'^([ \t]*)test\b[^{\n]*\{', re.MULTILINE)
COMMENT = re.compile(r"(^|[ \t])//.*", re.MULTILINE)


def production(text):
    kept = []
    rest = text
    while (match := TEST_BLOCK.search(rest)) is not None:
        kept.append(rest[:match.start()])
        end = rest.find("\n" + match.group(1) + "}", match.end())
        stop = len(rest) if end == -1 else end + len(match.group(1)) + 2
        kept.append("\n" * rest.count("\n", match.start(), stop))
        rest = rest[stop:]
    kept.append(rest)
    return COMMENT.sub(r"\1", "".join(kept))


def owned(relative):
    return any(Path(relative).match(pattern) for pattern in PROVIDER_OWNED)


def scan(paths, root, rules, allowed=frozenset()):
    found = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        code = production(path.read_text())
        for name, pattern in rules:
            if (relative, name) in allowed:
                continue
            for match in pattern.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                found.append(f"src/{relative}:{line}: {name}: {match.group(0)}")
    return found


def violations(root=SRC):
    core = [path for path in sorted(root.rglob("*.zig")) if not owned(path.relative_to(root).as_posix())]
    return scan(core, root, RULES, ALLOWED)


def codec_violations(root=SRC):
    return scan(sorted((root / "codecs").rglob("*.zig")), root, CODEC_RULES)


if __name__ == "__main__":
    found = violations() + codec_violations()
    for violation in found:
        print(violation)
    sys.exit(1 if found else 0)
