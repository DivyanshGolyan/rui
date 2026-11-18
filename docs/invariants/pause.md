# Pause point owner invariants

The pause controller is a test-only seam; these promises apply to its callers and fixtures.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| PAU-1 | Module | With test pauses disabled the owner occupies no storage. | Build configuration | `pause PAU-1 owner is zero sized when disabled` | `src/testing/pause.zig` |
| PAU-2 | Module | An armed arrival remains available to a later wait. | PauseController | `pause PAU-2 arrival before wait is retained` | `src/testing/pause.zig` |
| PAU-3 | Module | Concurrent arrivals receive distinct IDs and release independently. | PauseController | `pause PAU-3 concurrent arrivals have distinct ids and release independently` | `src/testing/pause.zig` |
| PAU-4 | Module | Poll stays pending until release and consumes the decision once. | PauseController | `pause PAU-4 poll remains pending until release and consumes once` | `src/testing/pause.zig` |
| PAU-5 | Module | Arming rejects faults unsupported by the point. | PauseController | `pause PAU-5 rejects unsupported faults before arming` | `src/testing/pause.zig` |
| PAU-6 | Module | Closing the controller unblocks parked workers with an error. | PauseController | `pause PAU-6 close releases parked workers with closed` | `src/testing/pause.zig` |
| PAU-7 | Module | Disjoint selections count matching arrivals independently and overlapping selections are rejected. | PauseController | `pause PAU-7 selections count matching contexts independently` | `src/testing/pause.zig` |
