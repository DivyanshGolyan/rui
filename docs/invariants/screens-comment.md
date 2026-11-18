# Screenshot comment invariants

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| SCR-1 | Module | Comparison columns include every size present in displayed states, with canonical sizes first and other sizes in manifest order; absent state and size combinations show a dash. | `screens_comment.render` | `RenderTest.test_screen_size_columns_cover_rendered_states` | `tests/ci/screens_comment.py` |
