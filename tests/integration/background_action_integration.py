#!/usr/bin/env python3
"""Focused background Action final delivery on a real Host and scripted provider."""
import os
import tempfile

from background_action_cases import prove_native_background, prove_model_action_read
import host_process
from host_process import canonical_fixture_root


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-background-action."))
    fixture_home = state / "home"
    fixture_home.mkdir()
    os.environ["HOME"] = str(fixture_home)
    print(prove_native_background(state))
    print(prove_model_action_read(state))


if __name__ == "__main__":
    host_process.enter()
    main()
