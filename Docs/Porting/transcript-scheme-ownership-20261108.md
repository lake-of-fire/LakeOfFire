# Main transcript scheme request ownership

Main base: a6d6f82b3156b7faaeeb59dce2ae1eb3021cfdf3.
Donor behavior: Lake #113 at 367775198f6b402cb5708896a44469abf788ccd3, still a separate v3-hotfix feature owner.

The main handler launched an unstructured task before installing its pending entry. A fast result could see no entry, decline delivery and then leave an installed completed request. Its callbacks also ran under a serial queue with one initial admission check, without checking stop/replacement between response, data and terminal callbacks.

The focused adaptation installs an exact attempt before launching work, confines state/callbacks to MainActor, rejects retired results after resolution, validates ownership between callbacks and retires before terminal publication. A malformed repeated start retires the old attempt too. Main's error and MIME behavior remain; the public synchronous initializer is retained with explicit nonisolated construction. An internal resolver seam and task accessor support tests of the real handler.

Thirteen regression methods exercise immediate/current completion, stop during response/data, same-object restart during response/data/finish/failure, old success/failure after replacement, delayed cancelled resolution, malformed restart and existing default errors. Resolver-entry waits have bounded XCTest deadlines; old/successor task handles are joined explicitly. These use mock WKURLSchemeTask callbacks and controlled resolution, not a hosted renderer or live WebKit loading journey.

The existing SwiftPM LakeOfFireTests target discovers the test source and already depends on LakeOfFireReader. The legacy generated Xcode project has explicit membership and was not edited; its membership/native discovery is not qualified. No host registration was added. Main ReaderWebView's default registrations include internal, reader-file and ebook, with additional handlers supplied separately. The main mounted transcript path was not established by this bounded audit; incomplete cross-repository code search is not caller-completeness proof.

Performed source/API/target review, independent source review and textual patch/whitespace checks. All Swift sources and tests are UNCOMPILED and UNRUN. Swift 5/6 actor-isolation/WebKit protocol compatibility and actual native callback behavior require qualification. No build, native test, CI dispatch, dependency pin, merge, production action or deployment occurred.

Registry admission, exact route validation, per-registration cleanup and finite Blob producer transport remain separate unresolved boundaries. This handler-only change does not close those gaps or supersede #113.
