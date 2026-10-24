# JavaScript composition evidence — 2026-10-24

This evidence branch preserves an isolated, tested composition. It is not a root dependency selection, a production tip, or a new feature PR. The separate source proposals remain independently reviewable. This is self-review because our implementations participate in the composition.

## Result and exact inputs

One grouped Node v24.22.1 / jsdom 26.1.0 batch passed **333/333 cases in 19 fixtures**, with zero failures, cancellations, skips or todos. All five production overlays merged cleanly. The complete composed viewer passed syntax checking; changed-line whitespace had no diagnostics. No source graph file changed after execution.

| Proposal | Exact head |
| --- | --- |
| Lake #347 — history receipts | `d50551c6a2630e684c98f8a5b885846a4f89bf8b` |
| Lake #341 — navigation controls | `2929647f7c1ace9deb426a58924c1f5c3f4a26d2` |
| Lake #281 — fixed-layout failure/retry | `3c7cbbe522ac5ef78dbc73001d7bd7a6f9b28b94` |
| Lake #288 — spine identity | `72ab8b1b5802e093b4b26029293a7b2ec01522e7` |
| Lake #293 — authored CFI assertions, child of #288 | `1690e95eac31cf75070c61db23a92c58a350d368` |
| Lake #340 — cache settlement | `5489c6b64d221ca03d116f910dab97206775fd67` |
| Lake #326 — wheel retry | `870265838aeaa74066ffede651eb44232d3b9917` |

The sole branch parent is #347. Its inherited #329/#313/#275 behavior remains present. Proposed #251 is `7c620c00c08129fbc47a97c0156949da3045f036`; frozen root-selected Lake remains `269f26450fa565326c6031e43da51211a7b2b67c`. The 50-file tested graph is identified by every Git blob, SHA-256 and byte count in `batch-inputs.json`; the rest of the repository inherits #347 and is not covered by this result.

## Preserved integration work

The new `Tests/JavaScript/view-fixed-layout-composition.test.mjs` executes the actual View, FixedLayout renderer, manual-navigation runner and NavigationHUD. Three cases cover valid void renderer success, failed spread preservation/retry, retired results, and Back's pending target through frame failure. DOM/frame transport and unrelated HUD paint collaborators are controlled; navigation state machines are production code.

One existing test-helper conflict was resolved in `paginator-rendered-restore.test.mjs`. #329's `sectionOverrides` and #326's `beforeOpen` are retained as separate arguments:

```js
const fixture = (sectionCount = 2, sectionOverrides = [], beforeOpen = () => {}) => {
```

The wheel helper supplies the third argument, acquisition callers keep the second, and both case blocks remain. The combined suite passed 16/16. This is a test integration resolution, not a new production finding. `composition.json` records all exact merge operands and resulting blobs.

## Reproduction and qualification

`batch-summary.json` preserves all 19 commands, per-fixture totals, exit codes, timings and complete local TAP hashes. Its absolute paths describe the executed scratch graph. To replay at this branch with the same already available runtime versions, set `JSDOM_MODULE` to the existing jsdom installation and run each recorded fixture from the repository root, for example:

```sh
node --test --test-isolation=none --test-reporter=tap Tests/JavaScript/view-fixed-layout-composition.test.mjs
```

Run each fixture in its own process; their host globals are intentionally isolated. Do not infer a real-browser result from the rendered-paginator suite: it uses controlled Node/jsdom geometry. No browser, WebKit, Swift/native build or test, project generation, CI dispatch, signing or CloudKit operation ran.

The later independent finding [5640556350](https://github.com/lake-of-fire/LakeOfFire/pull/347#pullrequestreview-5640556350) identifies the selected native history buttons' disconnected legacy DOM producer. Another owner is repairing that Core/Lake companion on `pro-reconcile-native-history-5640556350`; this JavaScript-only composition does not qualify the native producer or that unpublished successor.
