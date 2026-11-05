# Porting work: native saved-position admission and WebKit handoff

This publishes the previously unpushed native-restore candidate on top of #41's book-import head `23a1a5ce9039ebc63d0c11425863fb1797502cae`. All newer import/content/loader changes remain. No root pin, schema, original book or CloudKit state changes.

## Runtime contract

Zero and one are present saved fractions, not absence. A genuinely absent CFI/fraction remains a first opening. Non-finite/out-of-range present fractions throw instead of turning into CFI-only or no-target opening. Keep the original public value initializer source-compatible and revalidate it at the native bridge.

The shared policy and its five tests are exactly Lake #37's files at `7b3f06467c3eb51bb69be3ffd7e852fbaadc3674`: policy blob `510041f29e5200b3e71fc8c2511aac86bcdc46a4`, test blob `0fcbb1188303db371af65b92a39c9f92f7d4b16d`. The complete saved-value and bridge declarations move into same-module Foundation files rather than compiling alternate test implementations.

The actual #41 initialization handler awaits acknowledgment and saved-position preparation in its own task; it no longer swallows the read error or starts another unstructured task. Preparation checks cancellation before and after the read, including a noncooperative nil response. Errors do not call loadEBook at a different default position. This does not add error/retry UI or exact frame admission to the standalone #41 handler.

The paired Core #183 startup closure must preserve the caller task across its Realm-actor hop and use the validating value initializer. It ignores deleted rows and performs no writes. Core #172's selected-Article/read-ownership implementation remains a separate consumer composition and must not be replaced by older URL routing.

## Added execution boundaries

Twenty-seven Foundation cases comprise 22 candidate cases and five unchanged companion policy cases. Eight further handoff tests consume JSON emitted by the actual Swift bridge in the existing JavaScript loader; Reader construction, scheduling and native-message endpoints remain doubles.

Four new macOS tests use a real WKWebView, nonpersistent data and local HTML. The actual production dictionary is passed as named callAsyncJavaScript arguments. They verify numeric zero/one/interior values, absent versus CFI-only, byte-exact Japanese/decomposed CFI with historical zero, and independent request IDs. These are actual outgoing WebKit conversion tests, not EPUB layout or full SwiftUIWebView envelope tests.

The exact staged candidate passed 31 macOS tests (including all four WebKit tests), eight generated-wire tests and all 310 retained JavaScript tests in run 36478580768. Downloaded artifact 10994477103 SHA-256 `4ca806e7267a6bb12353f797ec04536d59532283037780e08cbfe2501f817d9c` was verified. The three complete staged output blobs were hash-checked before selection: protocol `cc417d2f180b248fbe62b747b654e5eaac384b8c`, standalone handler `4e5af0ea13fb01599f7d23b92fe8ded44ebe9fcb`, composed handler `90dc6a6f0b1fad245095957ded6663721071cdb6`.

The temporary staging script/workflow stored only immutable public source blobs, never refs, and are removed by the runtime commit. Final permanent CI is read-only and reruns the committed tree in macOS/Linux Debug/Release with explicit Swift 6 language mode. Its results must be checked separately; staged success is not assumed to be a final-head run.

## Remaining composition and acceptance

Lake #50 must retain its receipt-captured token, task-local native binding, opening preparation and evaluateJavaScript(requiring:) calls. Its restore stage can return the validated bridge request directly; do not replace that handler with #41's weaker standalone callback. Pair later #41 book-import changes and preserve #50's fingerprint/serving resource/path-limit fixes.

Full Core/Realm reads, exact consumer target selection, real reflowable/fixed-layout EPUBs, host retry/conflict/reopen UI, minimum deployments and Tuist/Project.swift source/test discovery remain unqualified here. No migration or signed two-client acceptance is claimed. Component passes do not prove final-write authority. Keep the PR draft.
