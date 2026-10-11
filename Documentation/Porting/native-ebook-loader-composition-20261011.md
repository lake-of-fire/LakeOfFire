# Native EPUB loader composition — 2026-10-11

## Exact source boundary

Compared retained #50 at 11b71f294a530cf38352065bceb05ce10aa88aa7 with #138 at ada3d27fbdc3bb954c1b294fb438a44ebd993618. Parent reviewed the complete retained loader and both regression files, the existing request/resource/coordinator helpers, and the targeted viewer and EPUB parser differences. The request helper, load coordinator and reusable resource owner already match the retained implementation; they are not duplicated here.

## Changes

- The current viewer now constructs immutable native sources with the supplied package session and passes the complete source to the shared native loader. Live and warm requests retain that captured source.
- Catalog, text, blob and direct-section requests carry one package session. A bound catalog must declare an existing package document; the EPUB parser selects that exact declared OPF instead of silently using the first rendition.
- Text-processing headers and deduplication keys retain package identity. Existing current-main rendering probes, presentation behavior, processing cancellation and cache generation ownership are preserved; the viewer is not replaced by the older file.
- Resource close/supersession checks remain after asynchronous fetch/decode boundaries. Destroy invalidates maps and the direct resolver.
- Carried 13 native-loader composition and 10 native-source/request cases. These are source counts, not passing test results.

## Validation and remaining work

Source/diff review only. JavaScript tests UNRUN; Swift remains UNCOMPILED/UNRUN. No native launches, build, project generation, CI dispatch, deployment or dependency pin changes. The source-only test registration checkpoint in Reader #384 remains 38 added native files / 469 methods; these JavaScript files are separate.

This composes the JavaScript consumer with the captured native handler prerequisites already present. It does not activate the optional native opening environment or complete the paired Core producer and completion-proof/cache-admission ports. #50 remains open. Next bounded action: compare the current Core opening producer and main view environment against the retained contracts, preserving newer APIs and excluding unfinished media/transcript feature work from hotfix scope.
