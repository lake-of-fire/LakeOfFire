# Porting work: downloaded-book import outcomes and row ownership

This extends Lake #41, based on 4c53c0f968ef6b702944a9cbcbc43684bc76c67b. It does not replace the separate OPDS work in #48 or automatically update #50's frozen identity/safety composition.

Source behavior: Lake v3-hotfix 780c3cfaf8a3422dbaab3e0a87ed84369b126248, BookDownloadImportAttempt.swift blob 0a911758896121c29f102b7a407be0573a9ff67d and Book Views.swift blob 685b26b2417c3a0cc6b208b4d2b006b225a25648. Source hotfix's grid still has the old failure behavior; applying the same contract to main's grid is an additional consumer repair.

## Implementation

Main's list and grid discarded ensureImported errors and nil results, then invoked onSelected or set wasDownloaded=true. This falsely completed the local import attempt and prevented the passive path from retrying. Both now call #41's existing ReaderFileImportOperation and reuse its typed imported/failed/cancelled outcome, shared recovery messages and cancellation handling. There is no second presentation mapper or duplicate copy of BookDownloadImportAttempt.

BookDownloadImportState records the returned library URL, not merely the existence of downloaded bytes. Only an imported result allows the selection callback. Failure clears the local success claim and retains a retryable message; cancellation does not mutate previous presentation. The alreadyDownloaded callback argument retains its original meaning.

HidingDownloadButton's downloaded badge is text, not a retry action. The rows distinguish Downloaded from In Library and provide a separate Retry Import button with a local dismissible alert. The list's retry action is outside its tappable header. The original top-tap/open path remains separate; real open errors now use the existing mapper and a local alert, with cancellation silent.

BookDownloadOperation owns one row-local task. Passive notifications do not interrupt an active selection. Explicit selection can supersede passive work; already-cancelled tasks may be replaced, avoiding a lost restart when task(id:) changes. Old completions/cleanup and cancelled waiters cannot overwrite or detach their successor. The view cancels its owner on disappearance. This cancels the row's waiter, not the shared global download or a committed file. Importer side effects remain governed by ReaderFileManager, not this presentation owner.

This is not the source hotfix's full cross-row BookLibrary OpenSelection/navigation-claim port. Parent downloadable rebinding, native navigation admission and whole-app lifetime remain separate integration work.

## Tests and qualification

Fifteen whole-file ownership tests pass locally on Linux Swift 6.2.1, Swift 6 language mode, warnings as errors, Debug and Release. Removing only the final cancellation/identity guard causes the superseded-refresh regression to fail an actual assertion, publishing [2,1] instead of [2]. This is a mutation control, not an exact-original-main runtime claim.

Fifteen additional native tests exercise the actual shared import operation and state: missing result, recovery, provider and package-limit failures, cancellation forms, selection only after success, preserved alreadyDownloaded values, and late cancellation retaining a committed temporary file without publishing success. These tests inject the importer operation; they do not exercise ReaderFileManager/Realm or assert on implementation strings.

The existing native package runner now includes both complete new source and test files, retaining all 65 earlier package/import cases and its documented archive-reader/app-cache extraction boundary. No earlier cases or fixtures are removed. Native execution is pending at publication; inspect exact-head macOS Debug/Release with released and locked-development ZIPFoundation. The separate portable runner executes only the 15 owner tests and does not qualify the import mapper or SwiftUI adapters.

    bash Tools/test-book-download-operation.sh
    bash Tools/test-package-resources.sh -c debug
    bash Tools/test-package-resources.sh -c release

Both changed full SwiftUI adapter files passed frontend syntax parsing only. Native row/grid typechecking and interactive failure/retry/dismissal remain required, as do generated Tuist test membership and the assembled Reader graph. Package component passes must not be presented as full app or UI acceptance.

No root pins, schema, original books, shared downloader policy, production CloudKit, signing, dependency requirements or main/v3-hotfix refs change. Nothing is merged. If #50 is selected as the integration candidate, carry this new #41 increment forward and requalify that exact composition rather than assuming ancestry to an earlier #41 head covers it.
