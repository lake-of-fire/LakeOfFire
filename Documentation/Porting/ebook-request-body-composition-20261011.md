# EPUB request-body composition — 2026-10-11 08:13 UTC

Reviewed #138 cb884e936fee3b8bb5b80ed89d94908628024ae3 and #50 ce8200d810d35b6ff18e0da2fe33341e5d87b73b. Ported only the bounded /process-text request-body boundary; the processor, cache, source capability and serving-session contracts are deliberately unchanged in this tranche.

Direct and streamed bodies reject empty, failed and over-limit payloads (8 MiB default) before processor entry. Streams use bounded 64-KiB reads and close on every exit. Cancellation does not publish partial accumulated bytes. Source review additionally corrected an Int.max read-hint overflow in the older helper and a missing cancellation check when a stream ends.

Three original helper cases and four additional boundary/real-URLRequest cases are authored UNCOMPILED/UNRUN. No builds, native launches, CI, dependency or production changes.

Remaining handler port requires composing processing-completion proof and session-bound serving with the paired text processor, environment and JavaScript changes. Do not copy the old whole handler over current architecture or claim snapshot prerequisite publication activated it.
