"""Classify committed paths and modes, never working-tree guesses."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from docs_only import ChangeKind, _entries, classify


class DocumentationTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.scratch.name)
        self.addCleanup(os.chdir, self.previous)
        self.addCleanup(self.scratch.cleanup)
        self.git('init', '-q')
        self.git('config', 'core.filemode', 'true')
        self.write('README.md')
        self.write('docs/guide.md')
        self.write('src/code.py')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.PIPE, text=True).strip()

    def write(self, name, content='A sentence. Another sentence.\n'):
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        self.git('add', '-A')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '--allow-empty', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def check(self, documentation):
        head = self.commit()
        self.assertEqual(classify(self.base, head),
                         ChangeKind.DOCUMENTATION if documentation else ChangeKind.NORMAL)

    def test_allowlisted_documents_and_assets(self):
        for path in ('README.md', 'ARCHITECTURE.md', 'CODING_STANDARDS.md', 'VERIFICATION.md',
                     'THIRD_PARTY_NOTICES.md', 'docs/guide.md', 'docs/nested/guide.md',
                     'docs/assets/diagram.svg', 'docs/images/screen.png', 'docs/images/map.svg',
                     'docs/spaces and ünicode.md', 'docs/new\nline.md'):
            with self.subTest(path=path):
                self.git('reset', '--hard', self.base)
                self.git('clean', '-fdq')
                self.write(path, 'Changed. Still on one source line.\n')
                self.check(True)

    def test_unknown_and_executable_owners_are_normal(self):
        for path in ('src/code.py', 'tests/ci/policy.py', '.github/workflows/check.yml',
                     'build.zig', 'build.zig.zon', 'package.json', 'unknown.md', 'AGENTS.md',
                     'CLAUDE.md', 'THIRD_PARTY.md', '.claude/skills/example/SKILL.md', 'docs/script.py',
                     'docs/data.json', 'docs/assets/script.js', 'docs/assets/image.png',
                     'docs/.hidden.md', 'clients/ts/README.md'):
            with self.subTest(path=path):
                self.git('reset', '--hard', self.base)
                self.git('clean', '-fdq')
                self.write(path, 'changed\n')
                self.check(False)

    def test_empty_and_mixed_diff(self):
        self.assertEqual(classify(self.base, self.base), ChangeKind.NORMAL)
        self.write('README.md', 'new\n')
        self.write('tests/ci/no_runtime_targets.py')
        self.check(False)

    def test_deleted_document_and_moves_check_both_owners(self):
        Path('README.md').unlink()
        self.check(True)
        for old, new, expected in (('docs/guide.md', 'docs/moved.md', True),
                                   ('src/code.py', 'docs/moved.md', False),
                                   ('docs/guide.md', 'src/moved.py', False)):
            with self.subTest(old=old, new=new):
                self.git('reset', '--hard', self.base)
                self.git('mv', old, new)
                self.check(expected)

    def test_executable_modes_and_transitions(self):
        self.write('docs/exec.md')
        Path('docs/exec.md').chmod(0o755)
        executable = self.commit()
        self.assertEqual(classify(self.base, executable), ChangeKind.NORMAL)
        Path('docs/exec.md').unlink()
        deleted = self.commit()
        self.assertEqual(classify(executable, deleted), ChangeKind.NORMAL)
        self.git('reset', '--hard', self.base)
        Path('README.md').chmod(0o755)
        changed = self.commit()
        self.assertEqual(classify(self.base, changed), ChangeKind.NORMAL)
        Path('README.md').chmod(0o644)
        regular = self.commit()
        self.assertEqual(classify(changed, regular), ChangeKind.NORMAL)

    def test_symlink_add_delete_and_type_transitions(self):
        Path('docs/link.md').symlink_to('guide.md')
        linked = self.commit()
        self.assertEqual(classify(self.base, linked), ChangeKind.NORMAL)
        Path('docs/link.md').unlink()
        removed = self.commit()
        self.assertEqual(classify(linked, removed), ChangeKind.NORMAL)
        Path('README.md').unlink()
        Path('README.md').symlink_to('docs/guide.md')
        replaced = self.commit()
        self.assertEqual(classify(removed, replaced), ChangeKind.NORMAL)
        Path('README.md').unlink()
        self.write('README.md')
        regular = self.commit()
        self.assertEqual(classify(replaced, regular), ChangeKind.NORMAL)

    def test_submodule_modes_are_normal(self):
        self.git('update-index', '--add', '--cacheinfo', f'160000,{self.base},docs/module.md')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'gitlink')
        linked = self.git('rev-parse', 'HEAD')
        self.assertEqual(classify(self.base, linked), ChangeKind.NORMAL)
        self.git('update-index', '--force-remove', 'docs/module.md')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'remove gitlink')
        self.assertEqual(classify(linked, self.git('rev-parse', 'HEAD')), ChangeKind.NORMAL)

    def test_committed_mode_wins_over_working_tree(self):
        self.write('README.md', 'changed\n')
        head = self.commit()
        Path('README.md').chmod(0o755)
        self.assertEqual(classify(self.base, head), ChangeKind.DOCUMENTATION)

    def test_invalid_refs_fail_instead_of_classifying_documentation(self):
        for base, head in (('missing-ref', self.base), (self.base, 'missing-ref')):
            with self.subTest(base=base, head=head):
                with self.assertRaises(subprocess.CalledProcessError):
                    classify(base, head)

    def test_malformed_or_unknown_raw_records_are_rejected(self):
        header = b':100644 100644 ' + b'a' * 40 + b' ' + b'b' * 40 + b' M'
        for raw in (b'garbage', header + b'\0README.md', header + b'\0\0',
                    header.replace(b' M', b' R100') + b'\0README.md\0other.md\0',
                    header.replace(b' M', b' T') + b'\0README.md\0',
                    header + b'\0docs/\xff.md\0'):
            with self.subTest(raw=raw):
                self.assertIsNone(_entries(raw))


if __name__ == '__main__':
    unittest.main()
