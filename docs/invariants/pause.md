# Pause point owner invariants

The pause controller is a test-only seam; these promises apply to its callers and fixtures. PAU-8 through PAU-14 run in the `pause-socket-test` fixture.

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| PAU-1 | Module | With test pauses disabled the owner occupies no storage. | Build configuration | `pause PAU-1 owner is zero sized when disabled` | `src/testing/pause.zig` |
| PAU-2 | Module | An armed arrival remains available to a later wait. | PauseController | `pause PAU-2 arrival before wait is retained` | `src/testing/pause.zig` |
| PAU-3 | Module | Concurrent arrivals receive distinct IDs and release independently. | PauseController | `pause PAU-3 concurrent arrivals have distinct ids and release independently` | `src/testing/pause.zig` |
| PAU-4 | Module | Poll stays pending until release and consumes the decision once. | PauseController | `pause PAU-4 poll remains pending until release and consumes once` | `src/testing/pause.zig` |
| PAU-5 | Module | Arming rejects faults unsupported by the point. | PauseController | `pause PAU-5 rejects unsupported faults before arming` | `src/testing/pause.zig` |
| PAU-6 | Module | Closing the controller unblocks parked workers with an error. | PauseController | `pause PAU-6 close releases parked workers with closed` | `src/testing/pause.zig` |
| PAU-7 | Module | Occurrences count all matching arrivals per point and filter regardless of arming time; passed occurrences and ambiguous overlapping selections are rejected. | PauseController | `pause PAU-7 selections count matching contexts independently` | `src/testing/pause.zig` |
| PAU-8 | Process | Arming is acknowledged before execution starts and rejected afterwards; arrivals remain available to a later wait. | Socket protocol | `test_pau_8_arm_ack_then_repeated_arrivals` | `tests/integration/pause_socket_test.py` |
| PAU-9 | Process | A pending wait does not block other socket requests. | Socket protocol | `test_pau_9_wait_does_not_block_other_requests` | `tests/integration/pause_socket_test.py` |
| PAU-10 | Process | Socket EOF closes the owner and releases parked work. | Socket EOF | `test_pau_10_eof_closes_owner_and_releases_worker` | `tests/integration/pause_socket_test.py` |
| PAU-11 | Process | A killed parked child is reported with its PID and exit status. | Process watcher | `test_pau_11_child_death_while_parked_reports_status` | `tests/integration/pause_socket_test.py` |
| PAU-12 | Process | Socket EOF unblocks the startup barrier. | Socket EOF | `test_pau_12_disconnect_unblocks_start_barrier` | `tests/integration/pause_socket_test.py` |
| PAU-13 | Process | A client call, sending and waiting together, ends within its watchdog even when the peer stops reading or never replies. | Python client | `test_pau_13_watchdog_bounds_wait`, `test_pau_13_watchdog_bounds_send_backpressure` | `tests/integration/pause_socket_test.py` |
| PAU-14 | Process | Socket EOF while the child lives is distinguished from child exit. | Process watcher | `test_pau_14_independent_eof_is_not_child_exit` | `tests/integration/pause_socket_test.py` |
| PAU-15 | Host | An interrupted validated model result cannot replace the committed interruption and its custody is released. | Model result pause and wire observation | `prove_sealed_interruption_and_cleanup` | `tests/integration/control_integration.py` |
| PAU-16 | Host | Controls remain available while a validated model result and inspection replies are held. | Model result pause and wire control | `prove_delivery_and_settlement_contention` | `tests/integration/control_integration.py` |
| PAU-17 | Host | A held model result does not stop HTTP/2 flow on a sibling stream. | Model result pause and fake HTTP/2 provider | `flow_while_execution_held` | `tests/integration/transport_h2_cases.py` |

The test-only socket adapter owns one inherited connected socket. Its `start`
request is acknowledged after all preceding arms have completed; the Host waits
for that request before starting execution. EOF closes the owner, waking parked
work and pending waits. The socket is marked close-on-exec. A killed child cannot
send an exit frame: the Python process watcher reaps it and synthesizes a
length-prefixed JSON child-exit event with its PID and return code. EOF while
the process remains alive immediately unblocks pending calls; callers can wait
independently for the child-exit event. The Host keeps the owner open until its
execution thread joins, including during shutdown. A worker paused at shutdown
remains parked until its test releases it or closes the control socket; a test
that forgets to do so fails at its client watchdog.

Known limit: a paused Action blocks other execution work until release; resumable polling will be added when an invariant test needs concurrent execution progress.
