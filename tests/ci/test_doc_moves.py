"""Keep the documentation move audit's routing and anchor checks discriminating."""
import unittest

from doc_moves import destination, headings, rewrite


class DocumentationMoveTest(unittest.TestCase):
    def setUp(self):
        self.anchors = {("ARCHITECTURE.md", "store-durability"): ("docs/contracts/store.md", "store-durability")}

    def test_root_and_relative_anchors_reach_the_same_owner(self):
        self.assertEqual(destination("#store-durability", "ARCHITECTURE.md",
                                     "docs/contracts/store.md", self.anchors), "#store-durability")
        self.assertEqual(destination("../../ARCHITECTURE.md#store-durability", "docs/agents/landing.md",
                                     "docs/agents/landing.md", self.anchors), "../contracts/store.md#store-durability")

    def test_migrated_links_are_idempotent_and_external_links_are_unchanged(self):
        text = "[Store](docs/contracts/store.md#store-durability) [Issue](https://example.org/#store-durability)"
        self.assertEqual(rewrite(text, "README.md", "README.md", self.anchors), text)

    def test_heading_anchors_ignore_fences_and_number_duplicates(self):
        text = "# Store\n```md\n## Not an anchor\n```\n## State\n## State\n"
        self.assertEqual(headings(text), {"store", "state", "state-1"})

    def test_colocated_evidence_uses_its_own_duplicate_heading_anchor(self):
        anchors = {("VERIFICATION.md", "skills"): ("docs/contracts/conversation.md", "skills-1")}
        self.assertEqual(destination("VERIFICATION.md#skills", "README.md", "README.md", anchors),
                         "docs/contracts/conversation.md#skills-1")

    def test_move_rebases_other_relative_paths(self):
        self.assertEqual(destination("tests/integration/host_process.py", "VERIFICATION.md",
                                     "docs/contracts/store.md", self.anchors), "../../tests/integration/host_process.py")


if __name__ == "__main__":
    unittest.main()
