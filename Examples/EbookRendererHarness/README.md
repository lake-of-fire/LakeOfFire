# Ebook Renderer Harness

Phase-4 harness for the LakeOfFire ebook renderer rewrite.

## Purpose

This harness is the fast iteration loop for the same-document renderer work described in:

- `/Users/alex/Code/lake-of-fire/swiftui-page-flip/specs/PHASE-4-lakeofire-ebook-renderer-rewrite.md`

It intentionally uses:

- the real `ebook://` shell URL flow
- the real `EbookURLSchemeHandler`
- the real `ReaderFileURLSchemeHandler`
- the real `ebook-viewer.html`
- the real `ebook-viewer.js`
- the phase-3 runtime pagination seam in `SwiftUIWebView`

## Current scope

The harness currently covers:

- importing a local EPUB through `ReaderFileManager`
- loading the shell with a real `ebook://ebook/load/...` URL
- preserving the existing startup contract
  - `ebookViewerInitialized`
  - `window.loadEBook({ url, layoutMode })`
  - `ebookViewerLoaded`
  - `window.loadLastPosition({ cfi, fractionalCompletion })`
- logging app-facing shell events
  - `updateCurrentContentPage`
  - `updateReadingProgress`
  - `ebookNavigationVisibility`
  - `finishedReadingBook`
  - `startOver`
  - `readerOnError`
  - `print`
- runtime pagination controls on one live `WKWebView`
  - enable/disable pagination
  - mode
  - gap
  - explicit page length vs `pageLength == 0`
- viewport presets
- writing-direction override
- direct jump by CFI or href
- structured pagination and renderer dumps

## Launching

The harness target is `EbookRendererHarness` inside the main `LakeOfFire` package.

Intended launch shapes:

```bash
swift run --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire EbookRendererHarness
```

Or with an EPUB path for auto-import:

```bash
swift run --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire EbookRendererHarness "/Users/alex/Downloads/[芥川龍之介] 羅生門.epub"
```

## Current status

As of 2026-03-31:

- `swift build --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire --product EbookRendererHarness` succeeds
- `swift run --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire EbookRendererHarness "/Users/alex/Downloads/[芥川龍之介] 羅生門.epub"` launches and stays alive long enough for a short terminal-driven smoke check
- the harness now mirrors its structured event log to stdout to make terminal launches inspectable
- the smoke path now reaches:
  - `ebookViewerInitialized`
  - `pageMetadataUpdated`
  - `ebookViewerLoaded`
  - phase-3 native pagination state on the live `WKWebView`
- the smoke path now exits cleanly with a gate summary again
- the latest smoke pass now closes all four phase-4 gates
  - `gate1SameDocumentMount = true`
  - `gate2NativePaginationReadback = true`
  - `gate3NavigationFacade = true`
  - `gate4AppFacingContract = true`
- the latest smoke pass now observes:
  - `updateCurrentContentPage`
  - `updateReadingProgress`
  - `ebookNavigationVisibility`

## Known issues

Current follow-up items:

- the current successful build still depends on a transient compatibility patch in:
  - `/Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire/.build/checkouts/LakeImage/Sources/LakeImage/LakeImage.swift`
- startup currently emits Realm / RealmSwift duplicate-class warnings in the debug dylib layout
- the latest smoke pass still reports `readerOnError` with message `Load failed` during navigation
- Gate 4 currently stays green because the shell now posts a safe fallback `updateReadingProgress` from section load after restore starts
- the deeper relocate-driven progress path is still not fully restored, so later hardening work should remove dependence on that fallback if possible
- a full interactive pass is still needed to verify:
  - same-document mounting
  - runtime pagination readback on one live `WKWebView`
  - navigation facade behavior through the real renderer
