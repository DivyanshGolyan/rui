# Lane B evidence (paused)
Source: origin/lane-b-peer-folds ab05d531d0c4a36943d768f720cd8cc0800584ee (e28e4531 + AGENTS.md self-stack rule). Contains main=stable 240aef2e.
- valid-control-240aef2e: TD1 retention 2/2 OK, exit 0 / direct 0, overlay+source unchanged at all 4 observations (zig-pkg pre-copied). binary 791aa499...
- candidate-fail-e28e4531-fixed-overlay: retention FAIL TruncatedResponse, exit 1 / direct 1, overlay+source unchanged. binary 6a67f43d... Fixtures: /tmp/td1-retention-hralxfeo, /tmp/td1-retention-yvj9cjs8.
- original-fresh-union-fail-e28e4531-src: first fresh-cache all-selector run, 5/6, retention TruncatedResponse. Fixture /tmp/td1-retention-0_dk_oul.
- Voided 240aef2e controls (overlay changed: zig-pkg fetched into overlay): inconclusive, receipts overwritten; recorded here only as fact.
- interrupted-bisect-a33df000 / -e7e660fc: stopped by PAUSE before completion; no receipt; inconclusive. Each had only a 2-line test-only rename in session_sequence_model_test.zig so the TD1 debug exe compiles.
- activity-integration-ab05d531.log: zig build activity-integration EXIT 0.
Classification: candidate-side regression (B), cause not yet identified.
Next action on release: finish bisect a33df000 vs e7e660fc with fixed overlays; trace TruncatedResponse in retention flow (suspects: fold DisplayCapture.folded / Blocks path, combined activity-page byte budget vs server/client buffers); fix; rerun unit + full TD1 fresh-cache; scoped Sol recheck of delta since c14d128f; C3 recheck if seam paths change; self-stack wip/land-18 after ref refresh + preflight.

## Closure (lane archived 2026-10-22 at user request)
Not a landing ref. Preservation only. The lane stopped while paused; diagnosis did not resume.
Code: origin/lane-b-peer-folds ab05d531 (this branch = ab05d531 + this evidence commit).
Unpublished at archive: none. The /tmp/wt-a33df000, /tmp/wt-e7e660fc and /tmp/wt-b worktrees held only the 2-line
TD1 test-only rename (already committed in e28e4531); the retained /tmp fixtures stay in the orb only.
Open item for the next owner: TD1 retention TruncatedResponse is a candidate-side regression (240aef2e passes, e28e4531 fails,
both with a fixed overlay). Next steps: finish the a33df000-vs-e7e660fc bisect, then follow the steps above.
