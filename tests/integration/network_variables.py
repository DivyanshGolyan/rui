"""The caller's network variables: its proxy and its TLS trust.

This module owns the names. host_process.py withholds them from every fixture
(its NETWORK) and hands them only to the opt-in live journey;
tests/ci/fixture_user.py passes them to a lane's run as root, after copying
each trust file or directory where the lane can read it. It imports only the
standard library and os_semantics, so root's Python can load it without the
fixture packages.
"""
import os_semantics

PROXY = ("https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY")
# OpenSSL's trust: a CA bundle file and a hashed certificate directory.
TRUST = os_semantics.TRUST_VARIABLES
NETWORK = (*PROXY, *TRUST)
