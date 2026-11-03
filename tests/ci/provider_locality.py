"""Core never special-cases a provider.

Provider-specific knowledge (the ChatGPT sign-in, OpenAI's error codes and
header names) lives in the files that own a provider: the codecs, the
`codex_*` sign-in files, `providers.zig`, the provider table and the CLI
commands that sign a provider in. Every other file in src/ is core, and its
production code (tests and comments aside) names none of it. Core asks the
provider table or the sign-in source a question instead.

Run directly to list violations; test_provider_locality.py gates on it.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src"

# Files that own a provider, relative to src/.
PROVIDER_OWNED = (
    "codecs/*",
    "codex_*.zig",
    "providers.zig",
    "provider_name.zig",
    "api_key.zig",
    "model_list.zig",
    "model_capability.zig",
    "cli.zig",
    "cli_args.zig",
    # The test roots import every module, the sign-in ones included.
    "tests.zig",
    "logic_tests.zig",
    "testing/*",
)

# What only a provider may know.
RULES = (
    ("imports a sign-in file", re.compile(r'@import\("codex_')),
    ("names a ChatGPT or Codex header", re.compile(r"chatgpt-account-id|x-openai-|x-codex-", re.IGNORECASE)),
    ("names an OpenAI error code", re.compile(
        r"\b(?:insufficient_quota|credit_balance_exhausted|organization_spend_limit_exceeded|"
        r"project_spend_limit_exceeded|usage_limit_reached|usage_not_included|cyber_policy|bio_policy|"
        r"misalignment_policy_violation|invalid_prompt|model_not_found|refresh_token_expired|"
        r"refresh_token_reused|refresh_token_invalidated)\b")),
    ("names a ChatGPT endpoint", re.compile(r"chatgpt\.com")),
    ("switches on a provider", re.compile(r"\bProvider\.(?:codex|openai)\b|\.(?:codex|openai)\s*=>")),
)

# Core files that must name a provider fact, each with why.
ALLOWED = {
    # The Host's own request fields, which h2 and every codec must never
    # write: the transport sits below providers.zig, so it lists them itself.
    ("provider.zig", "names a ChatGPT or Codex header"),
}

TEST_BLOCK = re.compile(r'^([ \t]*)test\b[^{\n]*\{', re.MULTILINE)
# A `//` comment starts the line or follows whitespace; `https://` in a
# string does not.
COMMENT = re.compile(r"(^|[ \t])//.*", re.MULTILINE)


def production(text):
    """The text with test blocks, named or not and at any indent, and `//`
    comments blanked, lines kept in place. A block ends at the first `}`
    line at its own indent."""
    kept = []
    rest = text
    while (match := TEST_BLOCK.search(rest)) is not None:
        kept.append(rest[:match.start()])
        end = rest.find("\n" + match.group(1) + "}", match.end())
        stop = len(rest) if end == -1 else end + len(match.group(1)) + 2
        # Blank lines keep every later line at its own number.
        kept.append("\n" * rest.count("\n", match.start(), stop))
        rest = rest[stop:]
    kept.append(rest)
    return COMMENT.sub(r"\1", "".join(kept))


def owned(relative):
    return any(Path(relative).match(pattern) for pattern in PROVIDER_OWNED)


def violations(root=SRC):
    found = []
    for path in sorted(root.rglob("*.zig")):
        relative = path.relative_to(root).as_posix()
        if owned(relative):
            continue
        code = production(path.read_text())
        for name, pattern in RULES:
            if (relative, name) in ALLOWED:
                continue
            for match in pattern.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                found.append(f"src/{relative}:{line}: {name}: {match.group(0)}")
    return found


if __name__ == "__main__":
    for violation in violations():
        print(violation)
    sys.exit(1 if violations() else 0)
