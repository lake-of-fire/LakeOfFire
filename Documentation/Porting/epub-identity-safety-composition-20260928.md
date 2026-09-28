# Porting work: EPUB identity and hotfix safety composition

## Exact inputs and branch purpose

This integration branch targets main and composes two previously separate candidates:

- Identity/owned serving #37: `7b3f06467c3eb51bb69be3ffd7e852fbaadc3674`.
- Hotfix safety/lifecycle/message port #41: `4c53c0f968ef6b702944a9cbcbc43684bc76c67b`.
- Common base main: `ac5894d936a15b9d305dafdaeac7afac5a0366dd`.

Both exact source heads are ancestors of the integration commit. Neither source PR has been merged to main or rewritten. This is a coordinated implementation candidate, not a root app release manifest. A later update to either input needs a new composition review and test run.

## Resolved overlap

Keep #41's current top-level load/restore coordinator, retry and completion gates, navigation/open generations, bounded package reads, and newer native message validation. Do not restore #37's obsolete window.loadEBook implementation or its permissive required-navigation result.

Bring forward #37's actual owned snapshot/lease registry, strict fingerprint, rendition selection, native initialization receipt capture, source registration and handler/resource/media paths. The viewer now supplies makeNativeEbookSource to the existing coordinator rather than the legacy source factory. An explicit native capability can be served through the complete selected Lake path rather than being discarded or rejected at the source factory. Missing, changed or withdrawn capabilities still do not acquire URL-only fallback authority.

The native resource loader is factored from the real viewer into ebook-native-loader.js, and the old inline implementation is removed. Actual live and warming getView calls pass the whole captured descriptor. Catalog, text/blob, processed-section and replace-text creation retain the same source/capability; bound EPUB initialization uses its native selected OPF. The viewer's process-text headers and deduplication key retain that capability too. Media hydration keeps #37's revocation behavior.

The normalizer keeps #41's stricter malformed-request rejection and target validation, which includes #37's zero/invalid fraction behavior. All #37 zero/invalid regression assertions remain. One obsolete source-regex viewer wiring test is replaced by an executable coordinator-to-native-loader test rather than updated to assert another source shape.

## New integration defect: inconsistent accepted and readable sizes

Strict fingerprint admission permits 128 MiB per entry by default. #41's generic resource reader intentionally defaults to 64 MiB; selecting both unchanged would fingerprint a larger entry successfully and then fail when serving its verified bytes.

ReaderEBookServingPackage now constructs its source using the captured fingerprint entry/count/aggregate limits. Ordinary resource and metadata defaults are unchanged. Explicit smaller fingerprint budgets still reject, strict path/checksum/membership checks remain, and withdrawing a capability still prevents reads. This does not make live-path reads or old capabilities authoritative.

The fingerprint component runner now copies the complete real ReaderPackageResourceLimits source required by the ported package reader. No substitute implementation or disabled bound is used.

## Tests and current qualification

Thirteen new JavaScript composition cases exercise actual native request/descriptor, resource loader, direct-section resolver and the production top-level coordinator. Coverage includes exact capability and literal path forwarding; selected renditions; live versus warming processing; same-URL different capabilities; forbidden/missing resource responses; supersession during catalog/byte decoding; descriptor mutation; and zero-target opening through the bound factory.

All 338 combined JavaScript cases pass locally on Node 22.16.0. This consists of #41's 310 cases plus #37's 16 additional cases, minus its replaced regex-only test, plus 13 new behavior cases. Repeated platforms/configurations are not additional unique tests. Reader construction/transport/browser scheduling remain test boundaries; this is not execution of the entire Reader or actual EPUB layout.

Three new native tests use actual strict fingerprinting, snapshots, the ported package reader and serving registry. One generates a compressed resource of exactly 64 MiB + 1 byte, verifies it can be served under the admitted fingerprint, and confirms the ordinary generic reader still rejects it. Others enforce a smaller explicit limit and revocation at an exact admitted boundary. The fixtures live in unique temporary directories and never access user books.

The exact four-file integration patch passed 338 staged JS cases in run 36469505956. Staging checked input/output Git blob identities and stored only the verified immutable public blobs; it did not update refs. The temporary workflow and patch are removed from the final runtime tree. Permanent workflows test the committed integration tree with read-only contents permissions. Final native/JS results and exact tested revisions belong in the PR description; local and stage evidence are not assumed to prove final native results.

## Required companion APIs and remaining release gates

The selected native initialization/serving code requires the document-binding APIs tracked by swiftui-webview #17 and the Common #127/Core #172 identity composition. Those source heads are not selected into the root app here. Core #183's importer still needs the #41 API now retained in this tree.

- Run all combined permanent workflows, including strict identity, generic resource/import, position and actual WKScriptMessage body tests. Investigate failures without omitting either side's regression suite.
- Build the actual full Lake/Core/Reader dependency graph and generated Tuist test targets. The isolated native runners omit full SwiftUIWebView envelope registration, ReaderFileManager/cache/SwiftUI integration and durable Realm writes.
- Exercise real reflowable/fixed-layout rendering, failed restoration/retry, same-URL concurrent windows, media/text processing, capability withdrawal and native delivery. Wrapper cancellation cannot undo arbitrary already-running renderer DOM effects.
- Finish the main Core saved-position source/admission, conflict/reopen/retry UI, current-Article/final-write lifetime, source-only first creation, Undo/support/predecessor/receipt, duration, persisted migrations and backup/restore. Native bridge zero support alone is not the full saved-zero consumer route.
- Qualify minimum deployments and signed two-client CloudKit with the exact composed revision tuple before root pins or ordinary activation change.

Original EPUBs, historical reading keys/epochs, schemas, signing, production CloudKit and rollout settings remain unchanged. There is no claim of complete app qualification or automatic production activation.
