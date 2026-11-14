"""Installed Host grammar shared by historical-release process diagnostics."""
import pathlib
import re
import subprocess


def help_text(binary, *command):
    """Probe without a Host or Store; older CLIs refuse unknown help with 1/2."""
    result = subprocess.run([binary, *command, "--help"], input="",
                            capture_output=True, text=True, timeout=5)
    assert result.returncode in (0, 1, 2), result
    return result.stdout if result.returncode == 0 else ""


class HostServeDialect:
    def __init__(self, binary):
        # Pin the build whose grammar was probed: an installed link such as
        # ~/.local/bin/rui moves to the candidate when it is installed.
        self.binary = pathlib.Path(binary).resolve()
        self.resource_first = bool(help_text(binary, "request", "inspect"))
        self.host_settings = bool(re.search(r"--set(?:\s|=|\])", help_text(binary, *self.serve())))

    def serve(self):
        return ("host", "serve") if self.resource_first else ("serve",)

    def host_arguments(self, store, endpoint=None, *, retry_waits=True):
        # Actual previous releases retain their installed grammar. Only the
        # candidate dialect uses generic settings; never teach an old binary
        # new flags or silently stop exercising the historical release.
        settings = (["--set", "execution.activeCapacity=1", "--set", "providers={}"]
                    if self.host_settings else ["--active-capacity", "1"])
        if endpoint is not None:
            settings += (["--set", f"providers.codex.endpoint={endpoint}",
                          "--set", "providers.codex.unauthenticated=true"] if self.host_settings else
                         ["--provider-endpoint", endpoint])
        return [str(self.binary), *self.serve(), "--store", str(store), *settings,
                *(["--test-retry-waits-ms", "50,100,150"] if endpoint is not None and retry_waits else [])]
