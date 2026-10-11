# Renderer navigation composition, 2026-10-11

Source-only review of Lake #138 at 308a32b99390448959376a9dcf2f588f3ad9328f against retained #50 at 642250f9dee22b0460871006e803ae57151f5c12.

## Missing behavior carried here
All differences in view.js were inspected. The older version retains the same current annotation, search, document-event ownership, relocate-location and history architecture. Its additional navigation/open ownership is now carried forward:
- CFI, href, fraction, selection and history traversal share command ownership.
- Invalid section indices and explicit renderer rejection cannot be published as successful navigation or appended to history.
- New commands, page turns, replacement renderers and closed/reopened views suppress obsolete completion and errors.
- Renderer-module loading cannot resurrect a closed view; overlapping opens require the exact open generation.
- Opening retires the prior renderer and clears its event bindings, history and progress maps before associating the new book.

renderer-operation-ownership.js, view-history.js and progress.js were verified byte-identical between the two exact heads.

## Evidence and limits
Carried the 31 behavioral cases in view-navigation-port.test.mjs. They use the real View and restore coordination with a minimal browser/renderer host. These tests are UNRUN. No build, test, native launch, project generation or CI dispatch was performed. Static review establishes the missing source behavior; it does not establish WebKit rendering parity.

This closes the View-level gap identified in current-main-epub-load-restore-20261011.md. The actual paginator/fixed-layout return and cancellation contracts still need comparison. Native owned-serving/session proof and processed-cache integration remain separate paired work; #50 is not fully superseded.

Next bounded action: compare paginator/fixed-layout operations and restore call sites, preserving newer main behavior.
