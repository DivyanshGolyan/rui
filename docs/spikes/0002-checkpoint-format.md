# Checkpoint-format spike

## Question

Can a logical agent's complete execution state be written and restored through a bounded,
self-validating record without reconstructing an object graph or retaining per-agent host memory?

## Record

Every checkpoint is exactly 65,600 bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | `ONEPAGE\0` magic |
| 8 | 2 | Format version, little-endian |
| 10 | 2 | Header size |
| 12 | 4 | Flags; zero in version 1 |
| 16 | 8 | Logical agent ID |
| 24 | 8 | Checkpoint generation |
| 32 | 4 | Page length; exactly 65,536 |
| 36 | 4 | CRC32 of the page payload |
| 40 | 4 | CRC32 of meaningful header bytes 0–39 |
| 44 | 20 | Reserved zero bytes |
| 64 | 65,536 | Complete Wasm linear-memory page |

CRC32 detects accidental corruption; it is not an authentication mechanism. A later format can add
authenticated integrity if the threat model requires protection from malicious modification.

Agent generations are a 32-bit domain value across task admission, completions, journals, and
checkpoints. The checkpoint retains its original 8-byte field for format stability; encoders zero
the high 32 bits and decoders reject them when nonzero.

## Bounds

The host allocates one 65,600-byte checkpoint buffer per active execution path and reuses it for all
logical agents. Disk usage grows with durable task count; resident checkpoint memory grows only with
configured execution concurrency.

Decoding rejects:

- truncated or oversized records;
- wrong magic, version, header size, page length, or flags;
- nonzero reserved bytes;
- header or page checksum mismatches;
- an unexpected agent ID;
- an unexpected checkpoint generation.

No page bytes are copied into an execution slot until all metadata, identity, generation, and
checksum checks pass.

## Current result

The density spike writes and restores 1,000 version-1 checkpoints while reusing one execution page
and one host checkpoint buffer. Agents 1, 500, and 1,000 are read back from disk and their identity is
verified through the restored Wasm core.

The standalone test suite covers round trip, truncation, header corruption, payload corruption,
unsupported metadata, stale identity, and stale generation.

## Deliberate omissions

This is not yet the authoritative journal or an atomic publication protocol. In particular, the
current spike does not:

- fsync checkpoint contents or the containing directory;
- write through a temporary name and atomic rename;
- record intent and outcome events around publication;
- choose between multiple checkpoint generations after a crash;
- recover from a valid prefix of a partially written journal.

Those semantics are the next durability spike. They should be added without changing the fixed
checkpoint record or allowing the host to infer agent policy.
