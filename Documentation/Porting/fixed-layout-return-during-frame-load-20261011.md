# Fixed-layout return during frame replacement, 2026-10-11

Source-correlated defect at #138 0ce3d53b193a5d523d99d0140c49dcd5805531b6: while a replacement iframe is loading, showSpread has cleared the old frame references but the committed spread index still names the last displayed spread. A goTo back to that index took the same-index shortcut, cancelled the replacement, rendered no frames, and reported success with empty content.

The shortcut now requires an actual retained frame. If all frame references have been cleared for an in-flight replacement, returning to the old index reloads that spread normally. The old pending iframe is cancelled and its late load stays obsolete. No prefetch/layout/generation algorithm is replaced.

One new behavioral case drives the actual FixedLayout through initial display, pending replacement iframe, return to the old index, fresh iframe completion and late abandoned-frame event. Existing section-source suspension coverage did not cover this later iframe phase. The suite now has 26 cases by source count, all UNRUN. No build/test/native/CI was launched.

This fixes the empty-content return path, not all in-flight renderer cancellation. Native owned-serving/cache composition and runtime qualification remain open.
