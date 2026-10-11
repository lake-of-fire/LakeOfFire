# Porting work: selected v3-hotfix behavior → main

**Planning-only draft.** This document scopes adaptations; it does not implement them. Target `main`, preserve its current modules and EPUB architecture, and do not merge the entire hotfix branch.

## Provenance and review method

Destination: `ac5894d936a15b9d305dafdaeac7afac5a0366dd`.
Source: `10fdf15c8ce4550b4e7900830843c1c8f2ac9f98`.
Ancestry is divergent (542 source-only / 603 main-only commits). The large merge-base diff contains module moves, generated projects and resources; it is not a missing-feature inventory. Check current destination behavior and existing PRs before selecting a patch.

## P0 — metadata/package resource bounds without parser regression

A concrete tip-to-tip difference was inspected in `Sources/LakeOfFireReader/Reader/Books/EPubParser.swift`:

- Main constructs `ReaderPackageEntrySource(localURL:)`, uses namespace-aware container/package parsing, optional cover metadata, and richer publication-date handling.
- The source explicitly requests `limits: .metadata`, validates package enumeration before XML parsing, and resolves contained metadata resource paths. Its parser/API differ from main and are not a replacement for main.

Port the **bounded untrusted-input behavior**, not the older parser. First inspect the destination package-entry source defaults and the current identity PR to establish which bounds already exist and which are still absent.

- [ ] Apply explicit metadata entry/aggregate limits at the appropriate current package-entry boundary, before large allocation or XML parsing, with cancellation/error behavior preserved.
- [ ] Test packed and unpacked EPUBs, oversized container/OPF entries, aggregate limits, traversal/symlink escape, malformed metadata, namespace handling, absent covers, reduced-precision dates and valid relative cover paths.
- [ ] Keep main's public result shape and correct metadata semantics. Do not import hotfix's mandatory-cover requirement or blanket `try?` handling over main's errors.

## P0/P1 — import, navigation and document lifetime

Map source `ReaderDocumentMutationAdmission`, `NavigationTaskManager`, `EbookURLSchemeHandler`, `ReaderFileURLSchemeHandler`, `BookDownloadImportAttempt`, `ReaderFileImportStorage/Presentation`, and `ReaderFileOperationErrors` into the current owning targets.

- [ ] Port stale-attempt/document cancellation and final-publish ownership where main is not already equivalent. An obsolete navigation/import must not publish success or modify the successor.
- [ ] Audit archive entry bounds, root containment, provider availability, and cancellation through the entire import/serve path. A transient provider error must not erase valid user data.
- [ ] Review `ReaderHTTPErrorRecoveryPolicy`, `ReaderSelectionErrorPolicy`, feed-following edits and annotation observation updates against current main semantics; port the behavior plus its tests, not broad UI or generated-file changes.
- [ ] Verify external segment-sidecar/document provenance against the consuming reader's contract before changing any payload. Keep application-specific read authority out of this generic library.

## Existing main work to preserve

[PR #37](https://github.com/lake-of-fire/LakeOfFire/pull/37) already owns EPUB identity, exact renditions, owned snapshot serving and strict fingerprinting. Review its current head before implementation and route overlapping fixes there or layer an explicit follow-up. Do not duplicate that work, advance it implicitly, or overwrite it with the hotfix's URL/package behavior.

Keep the modular `LakeOfFireContent`, `LakeOfFireReader`, files/core/library and other current products. Do not port `.manabi-backups`, Derived output, generated Xcode projects, unrelated PDF resources or dependency downgrades from the merge-base diff.

## Acceptance and rollout

- [ ] Record source commit/blob, destination counterpart and retained newer behavior for each implemented change.
- [ ] Port behavior tests into the correct package targets; do not test implementation source text with substring assertions.
- [ ] Execute archive/metadata/import/navigation tests and existing EPUB regression suites.
- [ ] Exercise real WebKit scheme cancellation, capture-before-async-work, and rapid navigation/close/reopen against the composed app.
- [ ] Qualify existing identity/snapshot behavior together with any newly adapted bounds; prior PR test results do not automatically qualify this composition.
- [ ] Only then merge selected library changes and let the consuming app advance its gitlink with a matching dependency manifest.

This planning commit changes no production source, manifest, gitlink, schema, signing or rollout setting. No package, Apple runtime or WebKit test pass is claimed.
