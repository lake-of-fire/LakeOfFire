# Transcript registry route identity

Base: LakeOfFire main `a6d6f82b3156b7faaeeb59dce2ae1eb3021cfdf3`.

Ports the registry byte-route identity guard from #113 (`367775198f6b402cb5708896a44469abf788ccd3`). HTML and WebVTT lookup now require the correct route kind and the registered asset's exact route. Unlike the donor's URL equality, this deliberately retains main's `absoluteString` comparison already used by `makeReaderContent`.

A key alone must not serve bytes for another source, an extra query, an outer fragment, or another authority/path. The source URL's own query and fragment remain embedded intact in `content-url`; no URL builder, parser, or canonicalization behavior changes. Registration and removal stay key-based, including latest-value replacement for the same source.

Scope excludes scheme-task lifetime (#529), loader changes (#334/#353), and package deletion ownership (#345/#370). Public APIs, actor isolation, and `makeReaderContent` are unchanged.

`TranscriptPageRegistryRouteIdentityTests` exercises isolated registry instances and byte results without Realm fixtures. It covers exact success, absent assets/VTT, wrong route kinds, outer mutations, embedded source fragments, replacement, and removal. Swift compilation and tests have not been run; native build/test execution is outside this change's verification scope. Review and run the focused tests in the supported Swift 6.2/Apple-platform workspace before merging.

This is serving-route identity, not registration-generation ownership. A replacement with the same key and same source URL intentionally keeps latest-value behavior. Stale registration/removal, already captured response bytes, registry retention limits, request/account admission, finite Blob transport and mounted main-app transcript wiring remain separate. No assembled app readiness is claimed. SwiftPM discovers the new file through the existing test target; legacy generated Xcode project membership was not changed or qualified.
