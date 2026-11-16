import unittest

from schema_number import advice
from test_store_schema_version import schema_bump_error


class SchemaNumberTest(unittest.TestCase):
    def test_a_branch_one_past_current_main_is_right(self):
        self.assertEqual(advice(60, 59, 59), (True, "This branch appends schema 60, one past main's 59."))
        self.assertTrue(advice(59, 59, 61)[0], "a branch that keeps the format need not follow main")

    def test_main_moving_past_the_base_asks_to_rebase_and_renumber(self):
        ok, message = advice(60, 59, 60)
        self.assertFalse(ok)
        self.assertIn("Rebase onto origin/main and renumber this branch's format from 60 to 61", message)
        self.assertIn("migration step .from = 60", message)
        ok, message = advice(61, 59, 60)
        self.assertFalse(ok)
        self.assertIsNotNone(schema_bump_error(61, 59))
        self.assertIn("Rebase onto origin/main and keep schema 61", message)

    def test_skipping_or_going_back_is_wrong(self):
        self.assertFalse(advice(61, 59, 59)[0])
        self.assertFalse(advice(58, 59, 59)[0])

    def test_every_number_it_accepts_passes_ci_after_the_rebase_it_asks_for(self):
        for base in range(55, 58):
            for main in range(base, base + 3):
                for branch in range(base - 1, main + 3):
                    ok, _ = advice(branch, base, main)
                    with self.subTest(branch=branch, base=base, main=main):
                        self.assertEqual(ok, (main == base or branch == base) and schema_bump_error(branch, base) is None
                                         and (branch == base or branch == main + 1))


if __name__ == "__main__":
    unittest.main()
