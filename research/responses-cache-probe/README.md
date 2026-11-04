# P1 probe: gpt-6.1-sol at https://api.openai.com/v1

Run 2026-11-04T09:10:43Z

| Check | Result | Detail |
|---|---|---|
| effort_update | PASS | HTTP 200, cached 3951/3969 |
| additional_tools | PASS | HTTP 200, cached 3951/4095, read_clock called: True |
| removed_tool | PASS | HTTP 200 |
| web_search | PASS | HTTP 200, web_search_call: True |

Checks for openai-responses/2 (D75-D77, D103, D150): a mid-conversation `configuration_update` effort change and an `additional_tools` item both keep the prompt cache, history holding a call to an undeclared tool answered "this tool was removed" is accepted, and hosted `web_search` works. Rerun with `OPENAI_API_KEY=... python3 probe.py`.
