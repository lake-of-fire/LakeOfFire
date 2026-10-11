# Porting work: storage, import outcomes and row ownership composition

Inputs: Lake #50 a006b0f4bd9a7c0565b935fc9b4d455a3f8c7675 and #51 db04ad527a7f915e99fba6abb3747aa7583fe69f, targeting main ac5894d936a15b9d305dafdaeac7afac5a0366dd. Root tracking: https://github.com/aehlke/manabi-reader/pull/189.

## Narrow runtime integration

Bring in #51's complete collision resolver, real storage adapter, package manifest, existing tests and native/portable runner. Apply only its installation block to the current ReaderFileManager. Its newer resolveAlreadyReadableEBookURL method, security-scope lifetime, destination routing, Realm configuration capture, metadata registration and all other code remain intact. Manager blob e9541548aef69722f7018f2dacb336597eb1ef1e becomes 5a1bfc4b14ee4afb8265b432ea88c2e40237905f. The exact #51 manager input was 42d07384c9909a2ea9f2582f9a687337aa924750, not a whole-file replacement.

All earlier native restore, exact document binding, serving/fingerprint, reader JavaScript, OPDS/catalog and row-import implementations remain unchanged. The final composition retains the source #51 history as an additional parent; #51 itself is not rewritten or merged to main. Production Package.swift and Package.resolved are unchanged. The new storage behavior is transient import comparison, not a persisted key or EPUB fingerprint migration.

## New combined native coverage

Twelve cases exercise the real SwiftCloudDrive local-directory storage adapter together with ReaderFileImportOperation, BookDownloadImportState and BookDownloadOperation. Two cases additionally execute the actual EPubParser and package reader against an installed directory. The after-install callback represents the metadata-registration seam; this does not simulate or execute ReaderFileManager's Realm registration. Physical fixture URLs are used without claiming reader-file URL mapping coverage.

Coverage: exact returned URL handoff and resolved location, idempotent repeat, occupied hash suffixes, failure or nil after successful copy followed by retry without duplicates, pre-cancellation, late cancellation, a superseding row selection after an earlier storage commit, provider cancellation preserving prior state, real EPUB metadata parsing, package-limit failure/retry and source-link rejection. A controlled continuation drives the supersession test; no sleeps or shared user files are used.

The existing native package runner now contains 142 methods: all 95 prior methods plus #51's 35 storage methods and these twelve combined cases. Repeated ZIPFoundation versions, platforms or build configurations are not additional unique cases; the standalone storage and owner suites overlap this set.

## Runner boundaries and provenance

The expanded fixture links the real SwiftCloudDrive at 0a84ea27d394fe0ed92e9b7809d84cfaa1942442, matching the production lockfile and #51. It retains the existing tools-5.10 language settings and macOS deployment declaration. The independent storage runner still uses explicit Swift 6 and warnings as errors. Do not describe both fixtures as one full-app Swift 6 build.

The package runner retains its two documented extractions: the complete archive-reader declarations without the trailing app cache, and the existing archive test file without two app-cache-only tests. All other source/test declarations are copied whole. The complete manager hook is hash-checked and syntax-parsed, not compiled with its Realm/SwiftUI graph.

Local Linux execution passed 18 collision tests in Debug and Release, 24 bound native-restore initialization tests in Debug and Release, and all 338 JavaScript tests. Native combined tests execute separately on macOS. Exact final CI results and artifact IDs are recorded in the PR and root index; passing source-PR or staged results must not be relabeled as final committed-tree execution.

The first native stage executed all 142 methods with two assertions failing in one newly authored method: the test compared a relative URL with a base against an absolute representation. The fixture correction separately checks the absolute standardized filesystem location and preserves the exact returned URL through operation and row state. No production URL normalization, test exclusion or weaker storage assertion was introduced. The other eleven new methods and all 130 retained methods passed in that first run.

All temporary staging code and its write-enabled workflow are removed when the final hook is committed. Staging checks both whole-manager hashes and only stores the expected immutable public blob; it never moves refs. Final permanent workflows are read-only.

## Remaining qualification

The full ReaderFileManager/Realm/SwiftUI graph, real provider/iCloud behavior, root Tuist source/resource membership, parent rebinding and cross-row navigation authority remain unqualified here. Real storage plus component outcomes are not database publication, interactive UI or a signed sync test. The storage comparison retains #51's documented limitations around concurrent/adversarial source mutation and full collision-time Data for regular files.

No root pin, main/v3-hotfix branch, schema, persisted identity, original book, signing, shared downloader policy, dependency requirement or rollout setting changed. No PR was merged to main.
