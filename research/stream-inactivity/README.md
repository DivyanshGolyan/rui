# Stream inactivity experiment

Question: would 60 seconds without receiving response-body data interrupt a request that would otherwise complete?

This throwaway probe records elapsed time to headers and the first response-body chunk, then each body read's arrival time, gap and byte count. It keeps no response content or credentials in the output. All body data counts, including SSE comments/heartbeats. It recognizes a complete terminal SSE event by its event name; it does not validate the model's answer or the terminal JSON payload.

Run one explicitly opted-in synthetic request using the existing Codex sign-in:

```sh
python3 research/stream-inactivity/probe.py --live --model gpt-6-astra --case reasoning --output /tmp/onepage-timing-reasoning.jsonl
```

Cases: `short`, `reasoning`, `longer`. No tools, repository content, automatic retries, credential refresh, or account changes. Authentication is read from the local Codex credential file in memory and sent only to the fixed Codex HTTPS endpoint. Output files must be new.

The experiment permits 300 seconds per blocking socket operation and has a 900-second total backstop, so it can observe gaps longer than the proposed 60 seconds. Those are experiment limits, not selected OnePage policies. HTTP rejection and missing terminal events are not successful samples.

## Interpretation

The first-body time includes connection, upload and header waiting. The between-body metric excludes those phases. Reads use `HTTPResponse.read1`, avoiding a wait to fill the requested 64 KiB buffer. TLS/HTTP buffering and local scheduling can still coalesce delivery: these are application-observed body arrivals, not packet timestamps. Headers and TCP acknowledgements are not counted as body activity. A final event ends measurement without waiting for connection closure.

This uses Python HTTP/1.1 and SSE, not Codex desktop's WebSocket path or OnePage's production libcurl adapter. A few successful synthetic samples cannot establish a safe upper bound, especially for extended reasoning, compaction, long context, load, network trouble, or Claude. A failed/backstop-ended sample is incomplete evidence. Repeat at the actual OnePage receive callback before selecting a production guarantee. Do not enforce 60 seconds while measuring its suitability.

References: the existing OnePage request headers in `src/codex_native.zig` and the [Responses API documentation](https://developers.openai.com/api/reference/typescript/resources/beta/subresources/responses/methods/create). The subscription endpoint remains a separate locally observed contract.
