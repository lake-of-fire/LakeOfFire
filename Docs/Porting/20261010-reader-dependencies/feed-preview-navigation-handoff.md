# Feed preview navigation ownership — October 10, 2026 (America/Toronto)

Bounded source review at Lake draft #138
`7867feb314a5c67bb4859f9b621a7d99f430c03f`, against fresh pending Lake #50
`0b91431f0fe04c45b24b08b427a5df66e87661b9` (open, base main).
The earlier explicit ReaderContent replacement repair is preserved.

## Concrete remaining lifetime

`LibraryFeedView.swift::LibraryFeedFormSections.refresh` captures entries and launches
an unstructured MainActor task. That task assigns preview selection, then awaits
`WebViewNavigator.load(content:readerModeViewModel:)`. There is no captured preview
request generation, task handle, mounted-owner admission or disappearance invalidation.
`onDisappear` flushes editing only. A queued old refresh may select after a newer refresh;
an already-running old refresh may issue native navigation after a newer preview selection.

At #138's current object, `WebViewNavigator+ReaderContent.swift` awaits
`ReaderContentLoader.load(content:readerFileManager:)`, then optionally awaits the
`persist:false` previous-content prefetch. It proceeds into reader-mode begin/cancel
and `load(URLRequest)` without checking preview ownership. Retirement of the content
resolver in `7867feb3` does not revoke this separate native navigation continuation.

## Existing pending owner: reuse, do not reimplement

At exact pending #50, that extension already accepts
`shouldLoad: @MainActor () -> Bool = { true }`. It checks at entry, after content URL
resolution, after optional prefetch, before reader-mode decision and before native request
issuance. Thus this navigator mechanism is pending source, not a newly missing helper.
Its default closure alone supplies no preview owner. #50's LibraryFeedView still assigns
`readerContent.content` directly and invokes the navigator without `shouldLoad`.

The next compatible composition should retain #50's navigator implementation and adapt
the current decomposed preview view. Do not copy #50's older LibraryFeedView endpoint over
the draft's captured editing/metadata repairs. No duplicate navigator helper is added here.

## Caller contract to implement with that composition

1. Reserve a request generation at synchronous refresh initiation, before enqueueing work.
   Check it at task entry before changing preview selection or issuing about:blank.
2. Capture the form's feed/storage incarnation and entry identity; reject replaced,
   deleted or archived owners. A queued task must not derive a new target from current state.
3. Retain/cancel the preview task on replacement and disappearance, and invalidate the
   request generation. Cancellation alone is insufficient for noncooperative await chains.
4. Use `replaceSelection(with:)` for admitted content/clear and provide #50's `shouldLoad`
   with request-generation, owner-lifetime and cancellation admission. Preserve newer selection
   if the old task resumes. Recheck after potentially reentrant reader-mode callbacks.
5. Observe errors from the owned task. A rejected `shouldLoad` currently returns Void normally;
   do not interpret that return as proof that a navigation request was issued.

Required production-path regression sources should control loader URL resolution and
previous-content prefetch separately, replace/clear/unmount the preview, and assert zero
obsolete reader-mode callbacks and zero obsolete native requests. Also cover queued old
task entry, same-URL record replacement, admitted successor completion and genuine loader
failure. A standalone generation predicate test does not prove native request admission.

## Evidence and limits

Read the current preview initialization/refresh/disappearance paths, current navigator
extension and loader entry, and pending #50's complete callback implementation plus actual
preview caller. Source/API inspection only; no build, test, package resolution, CI dispatch,
native launch or capture. Parent pins and original checkouts are unchanged.
Queued event-origin provenance, loader-side effects, global account/storage generation and
broader Reader render lifetime remain separate boundaries. This handoff neither implements
nor qualifies a mounted preview navigation fix.
