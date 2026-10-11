# Same-section synthetic restore navigation — 2026-10-11

Parent: Lake #157 `a32d31adbbe28121e0b7cab778f2784fd60c5440`.
Donor review: closed hotfix Lake #156 `3bcae6fb228c08bad80e287c884afe1ee8446792`.

Reviewed all nine changed-file diffs of #156 against current main. Main does not contain the donor book-action bridge/runtime, so copying those files would import a separate runtime authority. Its UUID helper has no matching main viewer caller in this bounded review; do not add unused infrastructure.

One independent hunk directly applies: main's visible-renderer goTo guard treats a same-section request with no numeric anchor as a no-op. Synthetic restore requests instead carry finite localPage, which main's paginator explicitly supports and uses to reposition. The wrapper could therefore swallow the restore before the paginator sees it.

Port the finite-localPage exception without importing book actions. Extract the existing guard predicate into main's existing ebook-restore-coordination module so the shipped decision is behavior-testable; all ordinary section/anchor/page calculations remain unchanged. The viewer still forwards this/target/remaining arguments to originalGoTo and preserves its existing skip return.

Three new pure behavioral cases cover finite local-page intent (including zero and an otherwise matching anchor), ordinary page/section decisions and nonfinite/absent local pages. The existing ten restore coordination cases remain (13 total). These are UNRUN, not browser/native integration results. Source/signature/caller review and remote byte-readback only.

No build, tests, browser/native app, generation, CI dispatch, merge, deployment, root pin or schema change. Donor-reported test counts do not qualify this candidate. Real same-section saved-location reopen and newer main request/terminal restore protocol remain integration gates when execution is authorized.
