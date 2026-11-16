"""Keep named TUI frames owned by linked, consistently shaped feature recipes."""
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / ".claude/skills/verify-rui"
HEADINGS = ["Sub-features", "How to get to it (user POV)",
            "Driving it with verify-rui", "Gotchas"]


def map_errors(states, features, readme):
    """Validate the frame-to-feature map, retaining every occurrence for diagnostics."""
    errors = []
    counts = Counter(states)
    repeated = sorted(name for name, count in counts.items() if count > 1)
    if repeated:
        errors.append(f"Duplicated frames.json states: {', '.join(repeated)}")
    owners = defaultdict(list)
    links = set(re.findall(r"\[[^\]]+\]\((?:\./)?([^\s)#]+)(?:#[^)]*)?\)", readme))
    for filename, text in sorted(features.items()):
        if filename not in links:
            errors.append(f"Unlinked feature: {filename} (add it to README.md)")
        headings = re.findall(r"^## (.+)$", text, re.M)
        if headings != HEADINGS:
            errors.append(f"{filename}: expected H2s in order {HEADINGS!r}, got {headings!r}")
        for number, line in enumerate(text.splitlines(), 1):
            if not line.startswith("Frame states:"):
                continue
            names = line.removeprefix("Frame states:").strip()
            if not re.fullmatch(r"`[^`\s,]+`(?:,\s*`[^`\s,]+`)*", names):
                errors.append(f"{filename}:{number}: malformed Frame states: line")
                continue
            for name in re.findall(r"`([^`]+)`", names):
                owners[name].append(f"{filename}:{number}")
    missing = sorted(counts.keys() - owners.keys())
    unknown = sorted(owners.keys() - counts.keys())
    if missing:
        errors.append(f"Missing frame states: {', '.join(missing)}")
    if unknown:
        errors.append("Unknown frame states: " + "; ".join(
            f"{name} ({', '.join(owners[name])})" for name in unknown))
    duplicated = sorted(name for name, locations in owners.items() if len(locations) > 1)
    if duplicated:
        errors.append("Duplicated frame states: " + "; ".join(
            f"{name} ({', '.join(owners[name])})" for name in duplicated))
    return errors


class VerifyRuiMapTest(unittest.TestCase):
    def test_repository_map(self):
        states = json.loads((SKILL / "scripts/frames.json").read_text())["states"]
        directory = SKILL / "features"
        features = {path.name: path.read_text() for path in directory.glob("*.md")
                    if path.name not in {"README.md", "frames.md"}}
        errors = map_errors([state["name"] for state in states], features,
                            (directory / "README.md").read_text())
        self.assertEqual(errors, [], "\n".join(errors))

    def feature(self, states="`chat`, `settings`"):
        return "# Feature\n\nVisible behavior.\n\n" + "\n\n".join(
            f"## {heading}\n" + (f"\nFrame states: {states}\n"
                                      if heading == HEADINGS[2] else "")
            for heading in HEADINGS)

    def errors(self, text, *, extra=None, readme="[Feature](./feature.md)"):
        return "\n".join(map_errors(["chat", "settings"],
                                   {"feature.md": text, **(extra or {})}, readme))

    def test_complete_map_and_multiple_lines(self):
        self.assertEqual(self.errors(self.feature()), "")
        split = self.feature("`chat`").replace("## Gotchas", "Frame states: `settings`\n\n## Gotchas")
        self.assertEqual(self.errors(split), "")

    def test_missing_unknown_and_duplicate_states_are_named(self):
        cases = [
            ("`chat`", "Missing frame states: settings"),
            ("`chat`, `settings`, `fake`", "Unknown frame states: fake (feature.md:"),
            ("`chat`, `settings`, `chat`", "Duplicated frame states: chat (feature.md:"),
        ]
        for states, expected in cases:
            with self.subTest(states=states):
                self.assertIn(expected, self.errors(self.feature(states)))
        errors = self.errors(self.feature(), extra={"other.md": self.feature("`chat`")})
        self.assertIn("Duplicated frame states: chat", errors)
        self.assertIn("other.md:", errors)
        twice = self.feature() + "\nFrame states: `chat`\n"
        self.assertIn("Duplicated frame states: chat", self.errors(twice))

    def test_links_and_exact_heading_order(self):
        self.assertIn("Unlinked feature: feature.md", self.errors(self.feature(), readme="feature.md"))
        self.assertEqual(self.errors(self.feature(), readme="[Feature](feature.md#gotchas)"), "")
        for text in (self.feature().replace("## Gotchas", "## Extra\n\n## Gotchas"),
                     self.feature().replace("## Sub-features", "## Gotchas", 1),
                     self.feature().replace("## Gotchas", "### Gotchas")):
            with self.subTest(text=text):
                self.assertIn("expected H2s in order", self.errors(text))

    def test_features_without_frames_still_need_links_and_headings(self):
        text = self.feature().replace("Frame states: `chat`, `settings`", "")
        errors = self.errors(self.feature(), extra={"hardware.md": text},
                             readme="[Feature](./feature.md) [Hardware](./hardware.md)")
        self.assertEqual(errors, "")

    def test_malformed_lines_and_duplicate_scenario_names(self):
        for states in ("", "chat", "`chat`,", "`chat`, settings"):
            with self.subTest(states=states):
                self.assertIn("malformed Frame states: line", self.errors(self.feature(states)))
        self.assertIn("Duplicated frames.json states: chat", "\n".join(
            map_errors(["chat", "chat", "settings"], {"feature.md": self.feature()},
                       "[Feature](./feature.md)")))


if __name__ == "__main__":
    unittest.main()
