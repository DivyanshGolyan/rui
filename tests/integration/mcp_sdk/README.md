# Real MCP SDK fixture

`server.mjs` uses Drift's pinned `@modelcontextprotocol/server` 2.4.0 transport:
`createMcpHandler(factory, { legacy: 'stateless' })` behind Node HTTP/1.1.
It binds an ephemeral loopback port and writes only that port to stdout.
Pass the bearer token as the first argument (or `MCP_TOKEN`).
Every route requires that token.

The launch-frame suite runs `npm ci --ignore-scripts` once and verifies that
Host startup catalogs `echo`, `fail`, `slow` and `progress` under `drift-sdk`.
The current public API has no catalog-list route, so each name and owning server
is verified through the Host's structured tool-name collision refusal.
Build-driven runs require Node; direct local runs may skip when Node/npm is absent.

The later tool-call suite can use `echo({text})`, `fail({})`, `slow({})` and
`progress({})` without replacing this server.
An authenticated `POST /release` releases all currently pending `slow` calls.
`progress` awaits a progress notification before answering, selecting the SDK's
SSE response path; this startup-only suite does not yet exercise that path.
