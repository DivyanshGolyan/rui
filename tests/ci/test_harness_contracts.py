"""Private fixture schema checks, discovered by the existing CI policy gate."""

import importlib.util
import mmap
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("host_process", ROOT / "tests/integration/host_process.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)

# Independent current schema, not expectations read from either codec.
FIELDS = (
    "rui_test_phase", "at_ns", "subject_kind", "subject", "turn", "operation",
    "attempt", "action", "scratch_used_bytes", "command_key", "kind", "control_key",
    "store_queued_at_ns", "lock_acquired_at_ns", "store_complete_at_ns",
    "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns",
    "post_commit_reply_ns", "host_total_ns", "start_ns", "wait_ns", "custody_occupied",
    "written_bytes", "http_version", "connection_id", "new_connections",
)


class ObservationCodecTest(unittest.TestCase):
    def test_stable_ids_and_cross_language_coherence(self):
        source = (ROOT / "src/TestObservation.zig").read_text()
        declaration = re.search(r"const FieldId = enum\(u8\) \{([^}]+)\};", source)
        self.assertIsNotNone(declaration, "native codec must declare explicit stable IDs")
        entries = re.findall(r"(\w+)\s*=\s*(\d+),", declaration[1])
        expected = dict(enumerate(FIELDS))
        self.assertEqual(len(entries), len(expected), "missing or duplicate codec field")
        self.assertEqual({int(value): name for name, value in entries}, expected)
        self.assertEqual(HOST.OBSERVATION_FIELDS, expected)

    def test_frame_decodes_every_id_independent_of_field_order(self):
        values = {name: f"value-{index}" for index, name in enumerate(FIELDS)}
        # The integer-valued native fields still arrive as decimal text.
        values.update(http_version="-7", connection_id="902", new_connections="0")
        payload = b"".join(
            struct.pack("<BH", index, len(value)) + value
            for index, name in reversed(list(enumerate(FIELDS)))
            for value in [values[name].encode()]
        )
        frame = struct.pack("<HBBQQQ", 28 + len(payload), 1, 0, 1, 37, os.getpid()) + payload
        self.assertLessEqual(len(frame), 512)
        state = mmap.mmap(-1, 40)
        state[:] = struct.pack("<QQQQQ", 1, os.getpid(), 37, 2, 0)
        reader, writer = os.pipe()
        observations = HOST._Observations(SimpleNamespace(pid=os.getpid(), poll=lambda: 0), reader, "status", state)
        try:
            self.assertEqual(os.write(writer, frame), len(frame))
        finally:
            os.close(writer)
        observations.close()
        self.assertEqual(observations.records, [dict(values, process=str(os.getpid()), run="37",
                                                   sequence="1", clock="awake_ns", trace_lost=False)])


class ImportSafetyTest(unittest.TestCase):
    def test_session_list_support_imports_ignore_process_arguments_and_workspace(self):
        source = """
import importlib, pathlib, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
sys.argv = sys.argv[2:]
original = list(sys.argv)
with patch.object(pathlib.Path, 'resolve', side_effect=AssertionError('import resolved caller configuration')), \
     patch.object(pathlib.Path, 'cwd', side_effect=AssertionError('import captured caller workspace')), \
     patch.object(subprocess, 'Popen', side_effect=AssertionError('import launched a process')):
    for name in ('session_list_integration', 'session_list_release_proof'):
        module = importlib.import_module(name)
        assert not hasattr(module, 'RUI') and not hasattr(module, 'CLIENT')
        assert callable(module.main)
assert sys.argv == original
print('import-safe')
"""
        for arguments in ([], ["foreign-runner", "-k", "--unrelated-option"]):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([sys.executable, "-B", "-c", source,
                                         str(ROOT / "tests/integration"), *arguments],
                                        cwd=directory, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "import-safe\n")
                self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
