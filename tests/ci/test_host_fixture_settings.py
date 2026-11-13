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
    def test_unconfigured_fixture_remains_provider_free(self):
        argv = ["rui", "host", "serve", "--store", "/missing-fixture-host"]
        self.assertEqual(host_process.isolated_host_arguments(argv), argv + ["--set", "providers={}"])
        self.assertEqual(argv[-1], "/missing-fixture-host", "must not mutate caller argv")

    def test_explicit_sources_and_hidden_endpoints_keep_selection(self):
        for options in (["--settings", "document.json"], ["--settings", "-"],
                        ["--set", 'providers={"openai":{}}'],
                        ["--set", "providers.codex.unauthenticated=true"],
                        ["--test-chatgpt-fixture-endpoint", "http://127.0.0.1/responses"],
                        ["--test-openai-fixture-endpoint", "http://127.0.0.1/responses"]):
            with self.subTest(options=options):
                argv = ["rui", "host", "serve", *options]
                self.assertEqual(host_process.isolated_host_arguments(argv), argv)

    def test_saved_settings_remain_authoritative(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "host.json").write_text('{"providers":{"codex":{}}}')
            argv = ["rui", "host", "serve", "--store", directory]
            self.assertEqual(host_process.isolated_host_arguments(argv), argv)

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
