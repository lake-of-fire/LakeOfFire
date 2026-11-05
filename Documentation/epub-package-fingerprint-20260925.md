# Exact EPUB package fingerprints

Companion to ManabiCommon PR #127: https://github.com/ManabiIO/ManabiCommon/pull/127

This draft provides strict, bounded package/rendition recognition. It is a prerequisite for location-independent reading, not the reader-side integration. It does not change import behavior, assign a BookID, migrate Realm data, download an iCloud placeholder or activate shared progress.

## Contract

`ReaderEBookPackageFingerprint.readSnapshot(at:packageDocumentPath:limits:)` consumes an immutable/coordinated local snapshot. The OPF path must be selected by the same parser as the viewer. The caller must revalidate the actual file observation and account/dataset binding when committing an identity association. File size or modification time alone is not proof of a stable snapshot.

The scanner retains resource paths, sizes and SHA-256 digests. The outer pathname, entry order, compression and ZIP timestamps are not identity inputs. Every regular package resource, including images and metadata, is an identity input. A metadata edit therefore changes the revision fingerprint, not necessarily the logical book identity. Neither this fingerprint nor a matching chapter filename authorizes reusing marked-read occurrences after content edits.

The selected package document is a separate part of revision identity. ManabiCommon's versioned revision key includes both the package digest and the exact UTF-8 OPF path. The scanner does not independently choose or rewrite the selected rendition.

## Frozen v1 digest format

The `field` encoding is an eight-byte unsigned big-endian UTF-8 byte count followed by those bytes. `integer` is an eight-byte unsigned big-endian integer.

1. `field("manabi-epub-package-v1")`.
2. `integer(number of regular resources)`.
3. For every resource sorted lexicographically by UTF-8 path bytes: `field(path)`, `integer(actual uncompressed size)`, `field(lowercase hexadecimal SHA-256 of resource bytes)`.

The tests contain an independently computed fixed vector. Changing this format requires a new version; do not reinterpret persisted v1 identifiers.

## Fail-closed limits

Strict identity scanning intentionally does not reuse the viewer's permissive entry enumeration, which can skip invalid or duplicate entries. It rejects duplicate/ambiguous file paths, traversal, symbolic links, unsupported entries, CRC failures, actual/advertised size differences, resource-budget exhaustion, enumeration errors and cancellation. Unicode-equivalent duplicate names are conservatively rejected instead of being collapsed into one hash input.

ZIPFoundation's Sequence may terminate at a malformed central/local header. The scanner separately validates the ordinary ZIP central-directory structure and its entry count, then requires its iterator to visit that complete count. A partial iteration never produces an authoritative fingerprint.

V1 supports ordinary single-disk ZIPs and unpacked directories. **ZIP64, multidisk archives and unsupported directory layouts fail closed.** This is an identity-scanner limitation, not a reason to delete, reject from the library, or clear progress for an EPUB the viewer otherwise supports. Production adoption must preserve legacy behavior when identity cannot be established.

## Tests and evidence

15 XCTest cases exercise actual ZIPFoundation archives and unpacked directories: recompression, entry reordering, timestamps, external renaming, image changes under identical XHTML, metadata revisions, duplicate paths, traversal, symlinks, missing selected OPF, MIME validation, byte/count budgets, corrupt central directories, incomplete iteration, the frozen vector, cancellation and retained resource metadata.

`bash Tools/test-ebook-fingerprint.sh` compiles the production scanner plus the same test file in a minimal macOS package, pinned to ZIPFoundation 0.9.20. The PR workflow runs that command. The scanner and tests were syntax-checked on Linux; **the native CryptoKit/ZIPFoundation tests have not been executed locally**. A passing native run is required before merge.

The feature branch is based on LakeOfFire main. It adds independent files only. The app currently pins a different LakeOfFire revision; backport/reconcile this change onto the selected hotfix dependency rather than moving the root to an unrelated main snapshot. Reader routing, coordinated snapshot acquisition, canonical Realm registration and full migration/BigSync qualification remain in the coordinated follow-up.
