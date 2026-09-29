# Porting work: collision-safe import storage

Destination: Lake main ac5894d936a15b9d305dafdaeac7afac5a0366dd.
Source: Reader-selected hotfix Lake 10fdf15c8ce4550b4e7900830843c1c8f2ac9f98; ReaderFileImportStorage.swift blob 45a046e37feedae4753dd566473e73f1e9409699 and the packageManifestDigest declaration in ReaderFileManager.swift blob 4ddf2d8ef906be36e35f8535600c8a42d3f0c1c1.
PR: https://github.com/lake-of-fire/LakeOfFire/pull/51
Root: https://github.com/aehlke/manabi-reader/pull/189

## Runtime change

The actual ReaderFileManager import path delegates destination installation to ReaderFileImportStorage. Its security-scope lifetime, destination routing, metadata/Realm writes and public API stay unchanged. The original manager blob 5048fb845893f5194e2a3bd3153330cabf7fc431 becomes 42d07384c9909a2ea9f2582f9a687337aa924750. Four production files change: that narrow hook and three complete storage declarations.

Main's URL-inequality check could attempt a forbidden copy even when the destination had identical bytes. A changed-content import chose one hash suffix without checking it, so repeating that import or encountering a shortened-hash collision failed. CloudDrive.upload already refuses overwrite: this is failed/redundant import repair, not a claim of previous destructive replacement.

The port inspects every candidate and reuses identical content. A destination-exists error after inspection is rechecked for a concurrent identical winner; only that exact Cocoa error is retried. Other read/copy errors propagate. New collisions advance through the existing first-suffix format, then -2, -3, etc. The original regular-file hash formatter is passed unchanged by the actual manager. Successful copy is the storage commit point; late cancellation does not delete that item or trigger another copy. Final import/presentation remains the caller's responsibility.

Package comparison now streams the hotfix's sorted manifest: relative paths, entry types, sizes and file bytes, including empty directories and hidden files. Stable symlinks contribute literal target bytes rather than target file data. Names and file boundaries cannot be lost through concatenation. The transient digest is not a persisted reading key, EPUB fingerprint, or schema; existing library items are not renamed. Directory collision tags intentionally reflect the corrected manifest rather than the old concatenation.

Destination-specific refinements recognize actual directories on either Apple platform, reject source symlinks, treat dangling destination links as occupied, fail on unsupported/escaped entries instead of skipping them, and reject streamed-size changes. These are refinements, not a byte-identical copy of the entire hotfix manager.

## Qualification and reproduction

    python3 Tools/test-import-storage-port.py --configuration debug
    python3 Tools/test-import-storage-port.py --configuration release
    python3 Tools/test-import-storage-port.py --native --configuration debug
    python3 Tools/test-import-storage-port.py --native --configuration release

The portable mode executes the complete production resolver and 18 complete XCTest methods with real temporary-file exclusive copies. The Apple mode additionally compiles the complete real storage adapter and CryptoKit manifest, using production-locked SwiftCloudDrive 0a84ea27d394fe0ed92e9b7809d84cfaa1942442. Eight tests use actual CloudDrive.localDirectory and nine test actual manifests: 35 distinct native cases, including the overlapping 18 portable cases. No mocked drive module, substituted digest or alternate resolver is used. The injected constant collision tag in native fixtures deliberately forces occupied suffixes; the production manager's formatter is unchanged.

Local Linux Swift 6.2.1, explicit Swift 6, warnings as errors: 18 Debug and 18 Release passes. Two helper-level controls compiled the exact original concatenateDataInDirectory and FileManager helper declarations; distinct filenames and file boundaries both failed real assertions. This is original helper execution, not a full original ReaderFileManager run. A separate unchecked-suffix mutation of the new resolver compiled and produced six assertion/errors across five methods; mutation failures are not additional product bugs.

Staged Apple run 36484359877 passed all 35 cases in Debug and Release, explicit Swift 6 and warnings as errors. Artifact 10998865630 was downloaded and SHA-256 verified: f13301311561fbb01ab0e4145aca2381e1ac94a685287d9162cb2d23376097a9. Both logs contain 35 named passes; all five executed source/test files and the exact dependency selection match the local candidate. The adapter patch was hash-checked and frontend-parsed before storing its one immutable blob. The initial native attempt compiled but had six assertions fail because the fixture root URL lacked its directory marker; the test-only correction adds an explicit root-path assertion and keeps all original expectations.

Temporary staging scripts and their write-enabled workflow are removed from the runtime tree. The permanent workflow has contents:read, tests committed source in macOS/Linux Debug/Release, and retains exact source manifests, inputs, fixture manifests and logs. Report final committed-tree results separately from the staged evidence above; the PR and root index carry that exact-head status.

## Remaining boundaries

Keep draft for the full ReaderFileManager/Realm/SwiftUI graph, metadata publication, actual iCloud/provider behavior and root Project.swift/Tuist test discovery. The focused graph compiles the real storage adapter, not the entire manager; the complete manager hook is syntax-checked only. Existing package dependencies and test membership are not replaced by the isolated fixture.

The comparison is not an atomic snapshot against adversarial/concurrent source replacement. Streaming checks detect size changes, not every possible same-size mutation or symlink race. Regular-file collision comparisons still hold complete Data as in the source; no measured performance, whole-app memory bound, directory resource quota or new filesystem security certification is claimed.

Compose with #41/#50 by taking the narrow import hook plus helper/tests, preserving their newer native read/serving methods; do not replace the whole manager with this main-based file. This PR does not modify those branches, root pins, schemas, historical identities, original user books, signing, shared downloader policy, rollout settings or production CloudKit. Nothing merged.
