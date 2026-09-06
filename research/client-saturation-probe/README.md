# Throwaway Unix HTTP client saturation probe

Question: what resources do bounded local clients retain, and does admission
headroom let a fresh short control through stalled ordinary transfers?

This is a native single-threaded C/poll harness using Zig 0.16's HTTP header
parser, derived from `research/http-memory-probe` at `9cd9e20`. It is not the
production Host or a complete HTTP server. Run on macOS with Apple Clang,
Zig 0.16 and Python 3:

```sh
python3 research/client-saturation-probe/run.py
```

The driver uses a unique temporary directory/socket, builds and stops only its
own process, and writes `results.json`. No provider calls or external network
access occur. Scratch files are immediately unlinked and closed on release.
The driver and probe raise only their own descriptor soft limit up to 4096,
within the existing hard limit. No machine-wide settings change.

## Method

Three fresh-process repetitions, rotated case order, at 16, 100 and 256 clients:

- incomplete headers (temporary classification state, not idle keep-alive);
- incomplete 1 MiB uploads with 4 KiB received into each scratch file;
- unread 1 MiB reports, fully written into scratch before delivery.

Each connection touches two reusable 8 KiB windows. The static table has 1024
88-byte records and is present in the same-process listener baseline. The
runtime connection bound is ordinary capacity plus one classification/control
place. These numbers are experimental controls, not chosen product settings.
The synthetic control is a zero-body `POST /stop` returning a two-byte response;
it executes no semantic mutation. Ordinary overload returns 503 and closes.

For each case, the driver samples the listener baseline, admits clients one at
a time, then takes eight held-state samples after a 50 ms settling interval.
For uploads/downloads it sends 20 serial fresh control requests and verifies
complete status/body, then verifies an ordinary request is rejected with 503.
Finally all clients close and descriptor/scratch cleanup is observed. Three
repetitions give 60 control observations per population and transfer type.

Server footprint uses `proc_pid_rusage` physical footprint. RSS, native thread
count, open descriptor count, scratch logical and allocated bytes are also
recorded. Python client costs and socket/kernel memory outside process accounting
are excluded. File allocated bytes do not measure filesystem cache RAM. Samples
are settled observations, not continuous high-water measurements.

## Results — 6 September 2026

arm64 macOS 15.7.7 (24G720), Zig 0.16.0 ReleaseFast, Apple Clang 17.0.0 -O2.
All rows show medians across three repetitions. Added footprint subtracts each
run's own listener baseline; control latency is client wall time through complete
response and EOF, with no SQLite admission or Host processing.

| Clients | State | Added physical footprint, KiB | Extra descriptors | Control median / maximum, ms |
| --- | --- | ---: | ---: | ---: |
| 16 | Headers | 352.1 | 16 | Not tested |
| 16 | Upload | 400.1 | 32 | 0.090 / 0.465 |
| 16 | Download | 416.1 | 32 | 0.064 / 0.374 |
| 100 | Headers | 1872.1 | 100 | Not tested |
| 100 | Upload | 1792.1 | 200 | 0.261 / 0.888 |
| 100 | Download | 1856.1 | 200 | 0.162 / 0.720 |
| 256 | Headers | 4288.1 | 256 | Not tested |
| 256 | Upload | 4320.1 | 512 | 0.541 / 0.898 |
| 256 | Download | 4400.1 | 512 | 0.272 / 0.535 |

All measured states had one server thread. Upload scratch was exactly 4 KiB per
client; completed report scratch was exactly 1 MiB per client. Closing all clients
returned descriptor counts to baseline and scratch counts/bytes to zero. The
reusable windows stayed allocated: retained increments for 100 uploads/downloads
were approximately 1808/1872 KiB. Reuse is part of the retained Host envelope,
not evidence that cleanup returns all process footprint to the OS.

Additional checks passed:

- Without headroom, 16 held uploads prevented a new control request succeeding.
- With a 0.3-second test header deadline, a caller trickling header bytes every
  50 ms expired, then a fresh control succeeded while uploads remained held.
- A 0.5-second test upload inactivity deadline released stalled uploads/scratch.
- A 0.3-second test delivery inactivity deadline released unread reports/scratch.
- A 10-byte upload spread over roughly one second succeeded under a 0.3-second
  inactivity deadline because each byte arrived about 0.1 seconds apart.

Shortened deadlines exercise state transitions; they do not validate the agreed
provisional 10/60-second inputs or select new production timeouts.

## Derivation and limits

For C total clients, this harness has up to 16,384*C bytes of touched reusable
windows, plus its fixed table and common process/library state. A production
startup-sized table would add its actual record size times C; this harness's
1024-record baseline must not be mistaken for zero metadata cost. Each held
transfer adds one socket and one scratch descriptor. Headers have no scratch.
The per-client file multiplier is as important as bytes: 256 tiny uploads still
hold 512 descriptors. The fixture's 1 MiB report is not a report-size limit.

For the final Host, derive client capacity from remaining memory, descriptor
and scratch-owner budgets after execution and fixed costs, using verified
per-owner multipliers. Measure kernel/socket costs separately. No overall Host
allowance has yet been chosen, so these measurements alone cannot select a
connection default. One spare place demonstrates an isolated incoming control;
it does not derive headroom for simultaneous controls and unclassified callers.

The first exploratory run attempted to connect 256 clients without waiting for
acceptance and received connection refusal. The listener backlog is another
finite boundary. The completed runs deliberately pace admission to isolate
occupied-transfer saturation. They do not certify connection-flood fairness or
promise immediate access under churn. Unclassified clients can fill headroom
until classified or expired. Ordinary 503 responses themselves briefly occupy
headroom until sent/closed. Acceptance and each client receive bounded service
per poll pass, but one disk write/capture is non-preemptible.

Not measured: production command parsing/validation, authentication/Store identity,
SQLite semantic commits, report capture contention, permission/cancellation
traversal, executor load, machine suspension, Host-imposed backpressure, malicious
HTTP behavior, sustained churn, concurrent control bursts or strict latency.
The two-byte control reply fits local socket buffering; it is not evidence for
large or stalled control responses. Slow-client handling cannot substitute for
bounded production command input/output. Exact command wire shapes remain open.

No production or accepted numeric policy is changed by this experiment.
