# P1b probe: gpt-6.1-sol at https://api.openai.com/v1

Run 2026-11-04T18:03:57Z

| Check | Result | Detail |
|---|---|---|
| head_function | PASS | HTTP 200, bash called: True |
| head_cache | PASS | HTTP 200, cached 4039/4082 |
| head_web_search | FAIL | HTTP 200, web_search_call: False |
| reword_redeclare | PASS | HTTP 200, cached 4079/4226, bash called: True |

## web_search control (web_search_control.py, same prompt "You must call the web_search tool now", twice each)

| Where web_search is declared | Output |
|---|---|
| top-level `tools` | 5-6 web_search_call, then message (both runs) |
| `additional_tools` at the head, with bash | reasoning, message: no search (both runs) |
| `additional_tools` at the head, alone | message: no search (both runs) |

Conclusion: a hosted tool declared in `additional_tools` is accepted (HTTP 200) but silently ignored. Function tools work there, including a later re-declaration that rewords one, with the cache intact.

Checks for openai-responses/2 tool declarations (D53-D55, D75): function tools declared in `additional_tools` at the head of the input are callable and cached, a re-declaration that rewords one is accepted, and hosted `web_search` there is ignored. Rerun from this directory with `OPENAI_API_KEY=... python3 probe.py` and `python3 web_search_control.py`.
