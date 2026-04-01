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

Smoke mode can also take narrow renderer-configuration overrides for repeatable terminal checks:

```bash
swift run --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire EbookRendererHarness \
  --smoke-test \
  --smoke-timeout=24 \
  --smoke-page-length=700 \
  --smoke-writing-direction=vertical \
  "/Users/alex/Downloads/[芥川龍之介] 羅生門.epub"
```

## Current status

As of 2026-03-31:

- `swift build --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire --product EbookRendererHarness` succeeds
- `swift run --package-path /Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire EbookRendererHarness "/Users/alex/Downloads/[芥川龍之介] 羅生門.epub"` launches and stays alive long enough for a short terminal-driven smoke check
- the harness now mirrors its structured event log to stdout to make terminal launches inspectable
- the harness smoke path now accepts smoke-only overrides for:
  - explicit page length
  - writing-direction override
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
- the example package now has two automated smoke tests:
  - default generated Japanese EPUB in `pageLength == 0` / view-length mode
  - generated horizontal RTL EPUB
  - generated vertical-writing EPUB with explicit page length and writing-direction override
- both automated smoke tests now also prove one runtime pagination gap reconfiguration on the same mounted `WKWebView` host
- both automated smoke tests now also prove disable/re-enable pagination mode restoration on the same mounted `WKWebView` host
- both automated smoke tests now also prove real href jump navigation (`reader.view.goTo(...)`) across chapter boundaries on the same mounted renderer path
- both automated smoke tests now also prove progress-fraction jumps (`reader.view.goToFraction(...)`) across the same mounted renderer path
- the smoke suite now records shell-box diagnostics for the mounted stage, mounted `foliate-view`, and nav chrome, and it asserts those are sane during automated runs
- that shell-box probe caught a real macOS harness regression: `#nav-bar` was stretching to the full viewport height, so the shell CSS now hard-pins it to a 63px bottom strip
- the smoke tests now parse the structured `smoke.summary` JSON directly instead of relying only on regex matches, so failures point at the exact broken field more reliably
- the smoke tests intentionally verify stable renderer/navigation seams (`next` / `prev`, href jump, fraction jump) instead of hidden shell button clicks, because the DOM button path is not a stable automation contract
- the smoke tests now also assert the same-document structure directly from the structured summary:
  - `iframeCount == 0`
  - non-empty live `contentURL`
  - live `sectionLayoutController` present

## Known issues

Current follow-up items:

- the current successful build still depends on a transient compatibility patch in:
  - `/Users/alex/Code/manabi/manabi-reader/Vendor/LakeOfFire/.build/checkouts/LakeImage/Sources/LakeImage/LakeImage.swift`
- the latest smoke pass still reports `readerOnError` with message `Load failed` during navigation
- Gate 4 currently stays green because the shell now posts a safe fallback `updateReadingProgress` from section load after restore starts
- the deeper relocate-driven progress path is still not fully restored, so later hardening work should remove dependence on that fallback if possible
- after a smoke-only disable/re-enable pagination cycle, native page-count readback can lag briefly even when mode and host restoration already succeeded
- package-warning noise on the local harness path is now narrowed to the transitive `keychain-swift` `PrivacyInfo.xcprivacy` manifest warning
- a full interactive pass is still needed to verify:
  - same-document mounting
  - runtime pagination readback on one live `WKWebView`
  - navigation facade behavior through the real renderer
