"""The shared documents keep one sentence per line, so edits to different
sentences of one paragraph merge cleanly, and the rewrite never changes what
a document renders."""
import subprocess
import unittest

from sentence_lines import ROOT, documents, findings, reflow, rendered

# Inputs where a careless split would change the rendered page.
HAZARDS = (
    "A | B\n--- | ---\nOne. Two | Three. Four",
    "Intro. Name | Value\n--- | ---\nx | y",
    "Done. ***", "Done. ___", "Steps follow. - not a list", "See this. # not a heading",
    "Items. 1. not a list", "Quote. > not a quote", "Line. ===",
    "```\n~~~\nA. B\n```", "````\n```\nA. B\n```\n````", "    ```\n\nPara. Two\n\n```\nIn. Fence\n```",
    "<pre>\nA. B\n</pre>", "<details>\nA. B\n</details>", "\tCode. More here", "-     code. Foo",
    "[x](<a. B>) end", '[x](u "T. U") end', "[a]: /u 'T. U'\n\n[a]", 'An <b title="A. B">x</b> y',
    "A <!-- c. D --> e", "Run `a. B` now.", "``x ` y. Z`` b. C", "Hard break. Kept  \nNext",
    "- First. Second.\n  1. Third. Fourth.", "> Quoted. Second.", "Use e.g. Zig here.",
)


class SentenceLinesTest(unittest.TestCase):
    def test_shared_documents_hold_one_sentence_per_line(self):
        found = list(findings(documents()))
        self.assertEqual(found, [], "run python3 tests/ci/sentence_lines.py to rewrite:\n" + "\n".join(found))

    def test_rewrite_never_changes_what_renders(self):
        for source in HAZARDS:
            with self.subTest(source=source):
                self.assertEqual(rendered(reflow(source)), rendered(source))
                self.assertEqual(reflow(reflow(source)), reflow(source))

    def test_rewritten_documents_render_as_on_main(self):
        for path in documents():
            name = str(path.relative_to(ROOT))
            main = subprocess.run(["git", "-C", str(ROOT), "show", f"origin/main:{name}"],
                                  capture_output=True, text=True)
            if main.returncode:
                continue
            with self.subTest(document=name):
                self.assertEqual(rendered(reflow(main.stdout)), rendered(main.stdout))

    def test_splits_a_paragraph_at_each_sentence(self):
        self.assertEqual(reflow("One thing. Two things! `Three` things? [Four](x) things."),
                         "One thing.\nTwo things!\n`Three` things?\n[Four](x) things.")

    def test_keeps_code_spans_and_lowercase_continuations_whole(self):
        for line in ("Run `a. B` now.", "``x ` y. Z`` b.", "It ends here. then lower case"):
            self.assertEqual(reflow(line), line)

    def test_continuations_sit_under_their_text(self):
        self.assertEqual(reflow("- First. Second.\n  1. Third. Fourth.\n\n> Quoted. Second."),
                         "- First.\n  Second.\n  1. Third.\n     Fourth.\n\n> Quoted.\n> Second.")


if __name__ == "__main__":
    unittest.main()
