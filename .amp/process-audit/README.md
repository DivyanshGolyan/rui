# Separate historical process-audit preservation

This auditor-supplied artifact is separate from L5 acceptance. Its presence preserves historical failed-run data; it does not establish a regression, a passed gate, a diagnosis or authority to implement audit findings.

The owner supplied private temporary bundle and checksum URLs. Both were downloaded with authenticated `amp files get`. The unmodified bundle has SHA-256 `01f3c1ce5c770e2e306baa656fe986ab1245cd293cd2c504691341cf70fe293a`. It contains 20 entries: two directories and 18 text files, including 14 failed logs, run metadata, source links and an internal `SHA256SUMS`.

All 17 internal manifest entries verified against the corresponding archive bytes. The manifest's own SHA-256 is `af43d27b3541262c9b4e53c7b09c5f3e05cbccff6836d6902d99ecb910856b29`. The initial verification reader did not account for the manifest's `./` prefix. Correcting that reader left the bundle unchanged. No bundled file was executed.

All 14 selected-run links and 200 complete-inventory links point to public `DivyanshGolyan/rui` GitHub Actions runs. A credential/private-key shape scan found no matches. `preservation-check.json` records the verification counts and scan result without publishing any detected credential value.

From the branch root, verify the outer files with:

```sh
sha256sum -c .amp/process-audit/SHA256SUMS
```

On macOS, use `shasum -a 256 -c .amp/process-audit/SHA256SUMS`. If you extract the archive to read it, verify its internal manifest from the extracted `process-audit/` directory. Do not execute its contents. This preservation adds no source, workflow, tests, retry or landing change.
