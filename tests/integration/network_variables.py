import os_semantics

PROXY = ("https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY")
TRUST = os_semantics.TRUST_VARIABLES
NETWORK = (*PROXY, *TRUST)
