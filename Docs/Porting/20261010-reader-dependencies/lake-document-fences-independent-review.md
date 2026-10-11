# Document mutation fence independent source review

Initial result: one concrete native-title admission defect; message-origin/write fencing otherwise has no new concrete defect found by source inspection. Read-only source review; no source edits, builds, parsing/typechecking, tests or commits.

## Exact evidence

Reviewed new `ReaderDocumentMutationAdmission.swift` blob `5f7a5d081a5b3fe96307cf8a6f80b7f2c62aa42e`, unstaged `ReaderMessageHandlersViewModifier.swift` blob `ddbab9407f6632ac73d6d6fd9ed7eaa1522f7ec4`, unstaged `ReaderViewModel.swift` initial blob `f367fb46c2eba0bfcfab0e435c35962aec15a280`, and complete new `ReaderDocumentMutationFenceTests.swift` initial blob `40bc0f9877f216b0118a975356467e2322cb0cf5`, in task18/LakeOfFire. Review read current HEAD `4041cfffec94af1eebb748608313909a4e943ec1` after initial source reads. Only requested candidate files and existing supporting call paths were inspected; other workers' patches are outside this review.

Supporting trace: native `Reader.swift:691` page-title callback, message parsers, `contentForWindowURL`, loader `getContent`/`loadAll`/`updateContent`, ReaderContentProtocol `asyncWrite`, and task18 swiftui-webview native receipt/token/commit-fence implementation. Native message token is captured before scheduling the handler. Document context activation/invalidation revokes the synchronous thread-safe commit fence. WebViewScriptCaller `hasAsyncCaller` publishes on a later main queue turn, while `canEvaluateJavaScript` synchronously reflects its installed async caller.

## Finding 1 — mounted native title callback can bypass admission during readiness lag

`ReaderViewModel.pageMetadataUpdated(title:author:)` chooses whether to capture document admission using `scriptCaller.hasAsyncCaller`. Immediately after native binding installation, actual `canEvaluateJavaScript` can be true while published `hasAsyncCaller` is still false. The method then creates a nil-token admission with `bindingIsCurrent: { true }`. Replacement or document retirement while its lookup is suspended will not invalidate this admission; same-URL stale title/author and metadata can persist. A mounted caller with unavailable document identity can likewise enter that unrestricted branch before readiness publication.

Use synchronous actual mount readiness for this decision; when it is mounted, missing exact token must fail closed. Reported directly to root before completion. Existing native fixture starts the callback through a Task and awaits provider entry, so it does not explicitly hold the readiness-lag window or check mounted/nil-document rejection in this public API.

## Message and writer conclusions

- RSS/title messages require main frame plus claimed URL/native frame main-document URL/current page agreement, excluding native-reader URLs. Image messages deliberately allow child frames but require the same top-document provenance agreement; they no longer trust the body main-document URL alone. Hash differences are accepted through existing hashless URL comparison.
- Capture requires the receipt token and a native commit fence; missing tokens and tokens from another caller cannot borrow the currently mounted binding. This is separate from URL equality, so same-URL binding replacement revokes admitted messages.
- RSS/image field updates check the captured admission inside the existing destination Realm write before mutation/metadata. Title path carries fixed target URL through lookup/reference resolution and rechecks admission/page after awaits, including inside its asyncWrite closure. DOM title refresh uses the same binding token; nil-token native path does not evaluate JS.
- Equality behavior for RSS/image remains guarded; title retains existing outside-write comparison and metadata update semantics. This review does not qualify changed-field concurrency/no-op journaling under a second simultaneous writer.
- Public ReaderViewModel initializer remains available as a convenience initializer and forwards to the new internal initializer with production observation enabled. Fixture-only `observeLibraryChanges:false` skips publishers but still installs the existing global resolver, which tests restore. No concrete signature/fixture API mismatch found by inspection.

## Durable RSS fallback and other limits

RSS first awaits `contentForWindowURL`. If displayed content does not match, that calls `ReaderViewModel.getContent` → `ReaderContentLoader.getContent` → existing persistent loader path. It can create a HistoryRecord before the post-await admission check. The new fence protects later RSS URL/title/availability field mutations; it does **not** admit or roll back this fallback durable creation. Candidate comment states this correctly. No whole-RSS-write closure claim is justified.

Native `Reader.swift:691` still queues a Task carrying page-title text only; it calls the public method later, which captures the then-current binding. It does not prove originating callback identity if that queued title came from a retired document. That caller provenance remains outside this patch, even after correcting readiness gating. The intentionally headless nil-token path also has no storage/account generation fence; URL rechecks constrain current display but not durable storage lifecycle.

Six initial fixture methods test helper URL/frame provenance, missing/foreign token, actual metadata lookup suspension with same-URL binding replacement, canceled writer, current writer and public native API. Real loader/Realm write path and mutation tracking helper are used, with an in-memory configuration and global configuration/provider/resolver restoration. Rejection asserts fields plus modified/explicit timestamp stability; it does not assert pending-journal generation. Gates use continuations without timeout, so fixture setup failure can hang at waitUntilEntered. No actual RSS/image handler end-to-end or fallback-creation oracle, native missing-document identity public callback oracle, in-transaction revocation/rollback, same-binding document generation rollover, real WebKit or native discovery/typecheck/runtime evidence is supplied. SwiftPM discovers by directory; explicit Xcode source registration was absent at read.

The fence is checked immediately before mutation in existing ordinary Realm transactions. The candidate does not introduce captured store admission, atomic multi-store rollback or a final durable ownership-preserving transaction contract. No account/storage/final rollback claim is made here.

## Readiness finding resolution

Final source reread confirms the public native callback now branches on synchronous `scriptCaller.canEvaluateJavaScript`, ReaderViewModel blob `3fb36e6e5bead7734cee6906dc7d31f86a8ed527`. Mounted callers capture an exact fence or return; readiness-publication lag cannot admit the unrestricted headless branch. Finding 1 is resolved by source inspection. Test blob remains `40bc0f9877f216b0118a975356467e2322cb0cf5`; no dedicated readiness-lag/mounted-nil-document public API oracle was added at this read. No further concrete new defect found; originating queued native title provenance and durable RSS fallback limitations remain open.

## Admitted RSS loader and demotion extension — source review

Reviewed subsequent loader blob `091307a9c97efa925ca40d42f7f32d7e4d4781bb`, HistoryRecord blob `feefeac104ae1868eb86d8348d28eb0475f83122`, and RSS caller revision blob `531cf5a5814760a0468e8f0397b7cc7ad498f30a`. No concrete new source/API defect found so far; associated extension tests pending author readiness at this source read. Existing bottom `updateSnippetTitle` body remains unchanged from the independently reviewed snippet candidate.

The new required-admission `getContent(forURL:source:admittingMutation:)` resolves loader URL directly and calls shared `loadContent` with `countsAsHistoryVisit:false`. It does not enter URL-only `inFlightGetContentTasks`, so one receipt cannot lend its predicate to a successor/window. Existing public `getContent` and `load` signatures/defaults remain. Shared read-only `loadAll` discovery can still coalesce, but each admitted caller checks its own authority afterward before writes. History destination configuration is retained before suspension; this is not account/storage-generation admission.

Predicate/cancellation checks occur at admitted entry, after discovery, inside new default-history transaction and mode/repair transactions, before/after main reference resolution and inside `refreshDemotedStatus`'s own write. Explicit navigation visit branches are unreachable from admitted entry. `refreshDemotedStatus` adds an optional default-nil predicate while preserving old calls; its mutation and metadata are rejected together before assignment when admission is revoked. It does not force authority checks for no-op demotion, and caller checks after return, which is sufficient to avoid a revoked no-op value escaping as admitted content.

RSS now calls the admitted loader rather than the unfenced `contentForWindowURL` fallback. Thus the earlier fallback-creation gap above is historical for the previous revision: this extension checks the receipt fence inside the default creation write. A creation already committed before subsequent revocation can remain even if later result/field writes are rejected; no rollback/atomic final-lifetime claim is made. Nonvisit lookup still permits default HistoryRecord creation and its model-default `lastVisitedAt = Date()`; countsAsHistoryVisit:false means no explicit visit refresh/restoration of existing records, not absence of all history storage.

Extension fixture reread now includes six methods in new `ReaderRSSDocumentAdmissionTests.swift`, interim blob `4d5fa74a471d7588617830b843f62c49f196920b`: revoked/canceled default creation; current creation then existing-visit timestamp preservation; overlapping same-URL windows with independent predicates; deterministic native readiness lag with mounted unavailable identity; and denied demotion at its actual production Realm write. Gates signal entry or completion and await bounded completion; `withLoaderRealm` releases gates and resets caches on thrown bodies. Revised metadata fixture blob `dda935943cc0cb03209c949e4152c36bd242bee3` similarly replaces its prior unbounded entry wait with bounded signals. Earlier unbounded-wait and missing readiness/demotion-oracle statements above are historical.

Concrete fixture-isolation issue reported to root: readiness method constructs ReaderViewModel, whose initializer overwrites global `ReaderContent.contentResolver`, but RSS helper at this revision restores only Realm configurations/providers. It must restore the resolver too, as the existing metadata fixture does. Production source remains no-new-defect by inspection. These cases do not force revocation after a transaction's admission check or establish rollback/final commit authority, and do not exercise complete WK message handlers end-to-end. All runtime/typecheck/native discovery limits remain.

## Final author-ready resolution

After root's author-ready notification, final source/test reread and hashes confirm:

| Candidate file | Final reviewed blob |
| --- | --- |
| ReaderContentLoader.swift | `c6dec0051da7e7e1990ae947181bb4b1b4ebc879` |
| HistoryRecord.swift | `feefeac104ae1868eb86d8348d28eb0475f83122` |
| ReaderDocumentMutationAdmission.swift | `5f7a5d081a5b3fe96307cf8a6f80b7f2c62aa42e` |
| ReaderMessageHandlersViewModifier.swift | `531cf5a5814760a0468e8f0397b7cc7ad498f30a` |
| ReaderViewModel.swift | `3fb36e6e5bead7734cee6906dc7d31f86a8ed527` |
| ReaderDocumentMutationFenceTests.swift | `dda935943cc0cb03209c949e4152c36bd242bee3` |
| ReaderRSSDocumentAdmissionTests.swift | `2c74c08995ca54301494ae447c546160752eb6ce` |

RSS helper now saves/restores global content resolver, resolving the fixture-isolation finding. It releases lookup gates and resets caches on both normal and throwing exits. Both new fixture files have bounded entry/completion coordination rather than indefinite joins. Final regression inventory is six metadata/provenance methods plus six admitted-RSS/readiness/demotion methods, twelve total. The denied-demotion fixture exercises the actual production write rejection; the readiness fixture installs a mounted caller with nil document identity and asserts the synchronous/published-readiness lag before calling the public API in that same actor turn. The earlier missing oracle claims for those two cases are historical. No further concrete source/API defect found in final revision.

Loader's final comment accurately states creation of defaults but no navigation-visit refresh of existing records. Admitted fallback now rejects revoked/canceled creation and mode/repair/demotion mutations before their assignments. URL-only outer mutation coalescing is bypassed; shared read discovery remains, with caller-owned admission checked afterward. Default APIs and independently reviewed snippet-bottom behavior remain retained.

Remaining oracles: complete RSS/image WK handler-to-Realm integration, revocation while waiting for an actual transaction rather than lookup, revocation after in-transaction predicate passes, final ownership/rollback, journal-generation equality, same-binding native document generation rollover, physical account/store replacement and callback provenance before method entry. Already committed creation is not undone by subsequent revocation. No test/build/parser/native discovery/runtime execution occurred; source review is not runtime qualification.
