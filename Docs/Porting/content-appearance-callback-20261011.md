# Reader content appearance callback port

Reviewed 2026-10-11.

## Exact sources

- Historical Lake #50: `11b71f294a530cf38352065bceb05ce10aa88aa7`.
- New main stack base, Lake #161: `bf1e828b117f3ab2b0641d263272d74f27621382`.

The older file carries explicit `@MainActor @Sendable` typing for the row appearance task and its appearance callback throughout the initializer/forwarding chain. Those annotations were absent in the newer file. This focused port restores the eight callback declarations and one task annotation only. It preserves the newer list implementation, invalidated-row guards, grouping, selection and deletion behavior. It adds no detached work or unchecked Sendable conformance.

The current FeedView appearance closure was inspected at the base head: it reads the appearing content key and updates initial-scroll view state. The callback now explicitly carries its main-actor contract through the public API instead of relying on an unannotated stored closure. Full downstream callers still require compilation.

## Evidence limits

This is a source-retention repair, not a claim that a new compiler failure was reproduced. No build or test was executed. Historical qualification branches #59 and #61 each failed their September 29 Debug consumer build and skipped Release; neither is qualification of this candidate. Do not restore their old workflows or dependency pins.

Required next check when execution is permitted: compile the actual LakeOfFireReader and downstream Reader targets with the selected Swift toolchain, including FeedView and external users of the public list initializers. Then run the maintained content-list regressions. No schema, root pins, release or production changes.
