# EPUB initialization: keep the receipt owner through publication

The native `ebookViewerInitialized` handler uses `message.javaScriptBindingToken`
**before** frame registration or any awaited acknowledgment. It checks the
native main-frame URL against the selected content and rejects missing/foreign
bindings. URL equality alone is not document ownership.

`ReaderEBookInitialization.perform` coordinates the actual registration,
acknowledgment, opening preparer, restore loader and final load callbacks. It
checks the one immutable token and caller cancellation between stages. Both
JavaScript operations additionally use `evaluateJavaScript(requiring:)` at their
own effect boundary. The handler awaits this operation directly; it does not
spawn an uncancelled replacement Task or swallow acknowledgment failure.
Diagnostic messages cannot register a stale viewer frame as a side effect.

This does not undo already committed recognition or an acknowledgment when a
later stage fails. Core's document permit still owns cancellation of package
work and final selection/first-use creation. The package capability is not
Article mutation authority, and the renderer never supplies a reading-record ID.

## Regression evidence

`bash Tools/test-ebook-initialization.sh -c debug` (or `release`) executes the
production MainActor stage coordinator with deterministic callback reentry and
suspension schedules. Eighteen XCTest methods cover same-URL replacement, another
window, missing/unbound receipts, cancellation, every stage's error, saved zero,
legacy no-preparer behavior, late results, and a fresh replacement receipt.
The pre-push Linux Debug/Release runs passed. A deliberate post-ack token recapture
made both replacement regressions fail assertions, not compilation.

The permanent read-only macOS fingerprint matrix runs this suite alongside the
existing snapshot, request and JavaScript suites. The Foundation tests do not
compile the full ReaderMessageHandlers/WebKit/Realm dependency graph. Full native
handler and app qualification remain required; no migration or two-client result
is implied by these tests. No EPUB bytes, stored reading keys/epochs, schema
versions or root dependency pins are modified by this fix.
