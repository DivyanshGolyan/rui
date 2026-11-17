#!/usr/bin/env python3
"""Focused background Action final delivery on a real Host and scripted provider."""
import os
import sys
import tempfile

from background_action_cases import prove_native_background, prove_model_action_read, prove_automatic_background, prove_message_background_and_stop, prove_client_action_stop
import host_process
from host_process import canonical_fixture_root


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-background-action."))
    fixture_home = state / "home"
    fixture_home.mkdir()
    os.environ["HOME"] = str(fixture_home)
    if "--stop-only" in sys.argv:
        print(prove_client_action_stop(state))
        return
    if "--message-only" in sys.argv:
        print(prove_message_background_and_stop(state))
        return
    if "--automatic-only" in sys.argv:
        print(prove_automatic_background(state))
        return
    print(prove_client_action_stop(state))
    print(prove_native_background(state))
    print(prove_model_action_read(state))
    print(prove_automatic_background(state))
    print(prove_message_background_and_stop(state))


if __name__ == "__main__":
    host_process.enter()
    main()
