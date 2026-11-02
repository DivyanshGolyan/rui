"""The shared documents keep one sentence per line, so edits to different
sentences of one paragraph merge cleanly."""
import unittest

from sentence_lines import ROOT, findings, reflow


class SentenceLinesTest(unittest.TestCase):
    def test_shared_documents_hold_one_sentence_per_line(self):
        found = list(findings(ROOT))
        self.assertEqual(found, [], "run python3 tests/ci/sentence_lines.py to rewrite:\n" + "\n".join(found))

    def test_splits_a_paragraph_at_each_sentence(self):
        self.assertEqual(reflow("One thing. Two things! `Three` things? [Four](x) things."),
                         "One thing.\nTwo things!\n`Three` things?\n[Four](x) things.")

    def test_keeps_abbreviations_code_and_lowercase_continuations(self):
        for line in ("Use a tool, e.g. Zig, here.", "Run `a. B` now.", "Version 0.S.N. is fine.",
                     "It ends here. then lower case", "Values (vs. Others) stay."):
            self.assertEqual(reflow(line), line)

    def test_never_starts_a_line_that_opens_a_block(self):
        for line in ("Steps follow. - not a list", "See this. # not a heading", "Items. 1. not a list",
                     "Quote. > not a quote", "Table. | not a row"):
            self.assertEqual(reflow(line), line)

    def test_leaves_tables_headings_fences_and_hard_breaks(self):
        source = "# A. B\n| One. Two |\n```\nA. B\n```\nHard break. Kept  "
        self.assertEqual(reflow(source), source)

    def test_list_items_continue_under_their_text(self):
        self.assertEqual(reflow("- First. Second.\n  1. Third. Fourth."),
                         "- First.\n  Second.\n  1. Third.\n     Fourth.")


if __name__ == "__main__":
    unittest.main()
