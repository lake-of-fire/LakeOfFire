# Porting work: EPUB identity and hotfix safety composition

## Exact inputs and branch purpose

This integration branch targets main and composes two previously separate candidates:

- Identity/owned serving #37: `7b3f06467c3eb51bb69be3ffd7e852fbaadc3674`.
- Hotfix safety/lifecycle/message port #41: `4c53c0f968ef6b702944a9cbcbc43684bc76c67b`.
- Common base main: `ac5894d936a15b9d305dafdaeac7afac5a0366dd`.

Both exact source heads are ancestors of integration commit `c4545e3259b3719ecce7eb4103e8a884f37dc842`. Neither source PR has been merged to main or rewritten. This is a coordinated implementation candidate, not a root app release manifest. A later update to either input needs a new composition review and test run.

## Resolved overlap

Keep #41's current top-level load/restore coordinator, retry and completion gates, navigation/open generations, bounded package reads, and newer native message validation. Do not restore #37's obsolete window.loadEBook implementation or its permissive required-navigation result.

Bring forward #37's actual owned snapshot/lease registry, strict fingerprint, rendition selection, native initialization receipt capture, source registration and handler/resource/media paths. The viewer now supplies makeNativeEbookSource to the existing coordinator rather than the legacy source factory. An explicit native capability can be served through the complete selected Lake path rather than being discarded or rejected at the source factory. Missing, changed or withdrawn capabilities still do not acquire URL-only fallback authority.

The native resource loader is factored from the real viewer into ebook-native-loader.js, and the old inline implementation is removed. Actual live and warming getView calls pass the whole captured descriptor. Catalog, text/blob, processed-section and replace-text creation retain the same source/capability; bound EPUB initialization uses its native selected OPF. The viewer's process-text headers and deduplication key retain that capability too. Media hydration keeps #37's revocation behavior.

The normalizer keeps #41's stricter malformed-request rejection and target validation, including #37's zero/invalid fraction behavior. All #37 zero/invalid regression assertions remain. One obsolete source-regex viewer wiring test is replaced by an executable coordinator-to-native-loader test rather than updated to assert another source shape.

## Integration defects: accepted and readable resource budgets diverged

Strict fingerprint admission permits 128 MiB per entry by default. #41's generic resource reader intentionally defaults to 64 MiB; selecting both unchanged would fingerprint a larger entry successfully and fail when serving its verified bytes.

ReaderEBookServingPackage now constructs its source using the captured fingerprint entry/count/aggregate limits. Ordinary resource and metadata defaults are unchanged. Explicit smaller fingerprint budgets still reject, strict path/checksum/membership checks remain, and withdrawing a capability prevents reads. This does not make live-path reads or old capabilities authoritative.

A further review found that v1 admits 16-KiB literal paths while the generic reader's default is 4 KiB. The serving reader now accommodates the already-validated v1 path envelope. Raw ZIP directory names include a trailing slash that the fingerprint excludes when accounting for normalized directory paths. Add at most one slash per admitted ordinary-ZIP entry to the generic catalog budget; the strict preceding scan still enforces its frozen 16-MiB normalized total and 16-KiB individual path limit. An overlong resource cannot gain authority merely because the subsequent decoder has a slightly larger envelope. The ordinary generic path limits and fingerprint v1 identity bytes are unchanged.

The fingerprint component runner copies the complete real ReaderPackageResourceLimits source required by the ported reader. No substitute implementation or disabled bound is used.

## Tests and qualification

Thirteen new JavaScript composition cases exercise actual native request/descriptor, resource loader, direct-section resolver and the production top-level coordinator. Coverage includes exact capability/literal path forwarding; selected renditions; live versus warming processing; same-URL different capabilities; forbidden/missing resource responses; supersession during catalog/byte decoding; descriptor mutation; and zero-target opening through the bound factory.

All 338 combined JavaScript cases passed locally on Node 22.16.0 and in the first permanent committed-tree integration run. This consists of #41's 310 cases plus #37's 16 additional cases, minus its replaced regex-only test, plus 13 new behavior cases. Repeated platforms/configurations are not additional unique tests. Reader construction/transport/browser scheduling remain test boundaries; this is not execution of the entire Reader or actual EPUB layout.

Six new native cases use real strict fingerprinting, snapshots, the ported reader and the serving registry. Three resource cases generate 64 MiB + 1 byte, enforce a smaller explicit cap, and verify revocation at an exact boundary. Three additional path cases exercise 16-KiB files/directories, the exact 16-MiB normalized path aggregate with raw trailing slashes, and rejection above the frozen fingerprint limit. Fixtures are unique temporary archives, never user books or extracted arbitrary paths.

At initial integration commit c4545e32, all four permanent fingerprint jobs in run 36469715050 passed 157 native package cases, 19 entry-path cases, 18 initialization cases and 338 JS cases. All three original resource-composition cases ran and passed. The four downloaded artifact digests and all 541 retained source/test/manifest files matched their tested tree `48edee7772a1c9cedcf5e829bd903c6155b33a76`; clean source status was checked. Apple Swift 6.1.2 and ZIPFoundation 0.9.20/locked development were used. This is historical evidence for the initial composition, not execution of the subsequent three path cases. Final follow-up results belong in the live PR description.

The exact four-file integration patch first passed 338 staged JS cases in run 36469505956. Staging checked input/output Git blob identities and stored only verified immutable public blobs; it did not update refs. Temporary workflow and patch are removed. Permanent workflows test the committed integration tree with read-only contents permissions. Stage, component and app evidence remain distinct.

## Required companion APIs and remaining release gates

The selected native initialization/serving code uses document-binding APIs tracked by swiftui-webview #17, which is already merged upstream. Its chosen revision still needs validation in the consuming dependency tuple. Common #127/Core #172 own application identity consumers and their remaining migrations/lifetimes. No root pins are advanced here. Core #183's shared importer API is retained in this tree.

- Run all combined permanent workflows, including strict identity, generic resource/import, position and actual WKScriptMessage body tests. Investigate failures without omitting either side's behavioral suite.
- Build actual full Lake/Core/Reader dependencies and generated Tuist tests. Isolated runners omit full SwiftUIWebView envelope registration, ReaderFileManager/cache/SwiftUI integration and durable Realm writes.
- Exercise real reflowable/fixed-layout rendering, failed restoration/retry, concurrent same-URL windows, media/text processing, capability withdrawal and native delivery. Wrapper cancellation cannot undo arbitrary already-running renderer DOM effects.
- Finish main Core saved-position source/admission, conflict/reopen/retry UI, current-Article/final-write lifetime, source-only first creation, Undo/support/predecessor/receipt, duration, persisted migrations and backup/restore. Native bridge zero support alone is not the complete saved-zero consumer route.
- Qualify minimum deployments and signed two-client CloudKit with the exact composed revision tuple before root pins or ordinary activation change.

Original EPUBs, historical reading keys/epochs, schemas, signing, production CloudKit and rollout settings remain unchanged. There is no full-app qualification or automatic production-activation claim.
