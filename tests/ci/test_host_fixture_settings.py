"""Host launch fixtures preserve exact provider selection after flag removal."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
import host_process

with patch.object(sys, "argv", [__file__, "/candidate/rui"]):
    import model_fixture


class HostFixtureSettingsTest(unittest.TestCase):
    def test_a_fixture_host_serves_no_provider_and_reads_no_live_catalog_unless_chosen(self):
        none, catalog = ["--set", "providers={}"], ["--set", "models.catalogUrl=" + host_process.UNREACHABLE_CATALOG]
        cases = (
            # (options, saved host.json or None, added arguments)
            ([], None, none + catalog),
            (["--settings", "document.json"], None, []),
            (["--settings", "-"], '{"providers":{}}', []),
            (["--set", 'providers={"openai":{}}'], None, catalog),
            (["--set", "providers.codex.unauthenticated=true"], None, catalog),
            (["--set", "providers.chatgpt.endpoint=http://127.0.0.1/responses"], None, catalog),
            (["--set", "providers.openai.endpoint=http://127.0.0.1/responses"], None, catalog),
            (["--set", "models.catalogUrl=https://localhost:1/api.json"], None, none),
            (["--set", 'models={"catalogUrl":"https://localhost:1/api.json"}'], None, none),
            (["--set", "providers={}", "--set", "models.catalogUrl=https://localhost:1/api.json"], None, []),
            ([], '{"providers":{"codex":{}}}', catalog),
            ([], '{"providers":{},"models":{"catalogUrl":"https://localhost:1/api.json"}}', []),
            ([], '{"models":{"catalogUrl":"https://localhost:1/api.json"}}', []),
            (["--set", "models.catalogUrl=https://localhost:1/api.json"], '{"providers":{"codex":{}}}', []),
        )
        for options, saved, added in cases:
            with self.subTest(options=options, saved=saved), tempfile.TemporaryDirectory() as directory:
                if saved is not None:
                    (Path(directory) / "host.json").write_text(saved)
                argv = ["rui", "host", "serve", "--store", directory, *options]
                before = list(argv)
                self.assertEqual(host_process.isolated_host_arguments(argv), before + added)
                self.assertEqual(argv, before, "must not mutate caller argv")

    def test_model_endpoint_is_exact_and_credential_free(self):
        argv = model_fixture.host_arguments("/store", "http://127.0.0.1/responses",
                                            "--set", "execution.activeCapacity=7", active_capacity=2)
        assignments = [argv[index + 1] for index, arg in enumerate(argv) if arg == "--set"]
        self.assertEqual(assignments, ["execution.activeCapacity=2", "providers={}",
                                      "providers.codex.endpoint=http://127.0.0.1/responses",
                                      "providers.codex.unauthenticated=true", "execution.activeCapacity=7"])
        self.assertIn("--test-retry-waits-ms", argv)

    def test_provider_free_model_launcher_works_without_readiness_wrapper(self):
        argv = model_fixture.host_arguments("/store", None)
        self.assertIn("providers={}", argv)
        settings = model_fixture.host_arguments("/store", None, "--settings", "document.json")
        self.assertNotIn("providers={}", settings)
