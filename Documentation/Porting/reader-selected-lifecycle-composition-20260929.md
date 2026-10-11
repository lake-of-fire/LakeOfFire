# Porting work: compose #50 with Reader-selected lifecycle hardening

Base composition: Lake #50 at `ded9cce72091c0f561f4917976b9e5e46395fb33`.
Reader-selected lifecycle source: Lake #53 at `35e0a7e65ce63365a9923a92fac832ad087c549b`.

This branch preserves #50's safe legacy migration, collision-safe imports, document-bound EPUB serving, native restore, OPDS/catalog ownership, book-open ownership and existing qualification harnesses while adapting #53's Reader-selected lifecycle work.

## Merge discipline

The original direct #53 → #50 feature PR conflicted because both branches changed five runtime files. Generated project/lockfile churn from #53 was deliberately excluded:
- `LakeOfFire.xcodeproj/project.pbxproj`;
- `Package.resolved`;
- the comment-only `Package.swift` delta.

All non-overlapping lifecycle source/resource/test files were copied from #53. The five overlaps were reconciled semantically:

1. `ReaderFileManager.swift`: all 13 lifecycle hunks applied with exact context onto #50. Generation-fenced complete inventory/orphan publication is retained alongside #50's collision-safe import storage and migration work.
2. `ReaderWebView.swift`: preserve #50's per-reader package-session store; add stable website-data-store identity, pool lifetime owner and processed-payload admission from #53.
3. `ReaderJavascriptMessages.swift`: #50 moved fractional payload parsing into `ReaderPositionMessagePayloads.swift`; strict #53 scalar semantics were applied there instead of resurrecting the old parser location.
4. `ebook-viewer.js`: add native lookup payload/producer generation fencing on top of #50's current viewer.
5. `EbookURLSchemeHandler.swift`: preserve #50's synchronously captured serving lease as the outer authority, then add #53's bounded 8 MiB process-text body, mutually-consistent package-source capability, processing-completion proof, cache/final payload admission, and entry-source checks. The capability guard also covers #50's newer `/entry-session/` route.

`ReaderEbookTextProcessor.swift` retains #53's explicit main adaptation to SwiftSoup's canonical `outerHtmlUTF8ReusingSourceOutsideBody()` API.

## Important SwiftSoup implication

Reader root main currently selects a divergent SwiftSoup branch containing older `outerHtmlUTF8FromCurrentTree*` APIs because Reader's selected Lake revision still calls them. This composition removes that dependency from Lake by using the canonical source-reuse API, making a later bounded root SwiftSoup hotfix pin possible. Do not advance SwiftSoup independently before this Lake composition is selected.

## Qualification

This branch is exposed as a draft PR to Lake main so every existing #50 and #53 pull-request workflow runs on the exact combined tree. It must not replace #50's head until those results are inspected.

No production Reader pin, schema, persisted reading identity, original user file, signing, rollout or CloudKit state changes.
