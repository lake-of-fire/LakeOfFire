# Reader-main Lake dependency tuple qualification

This branch contains no runtime source changes beyond Lake #50. It exists to compile the exact Lake integration against explicit sibling repositories on public GitHub runners.

Lake:
- `fa2e2f771f7d6fca3351da17abd46df04e31734b` — #50 exact qualified head.

Changed/converged siblings:
- SwiftSoup `e870c5ff5efacfce3aa423356fa918e6614f0e50` — canonical master.
- swift-readability `438724ab13e428a01ba4bb10ff6fbc8fa6c7330b` — canonical/hotfix main.
- swiftui-webview `bb4b8d682b2befdf3bcf4285e3dae08771be2679` — canonical main.
- SwiftUtilities `475973026ca1e953d016ff78e65c0be5bb4885d5` — canonical main plus Reader vendored UI parity; production sources correspond to root #207 after composing root #190's StableHash port.

Unchanged Reader-main siblings:
- swift-brave `84f2ba37df3992db73f62b99a3389cee886cbce5`
- RealmSwiftGaps `3c0ccf00d734cae997bd34654a4f2efd01397531`
- BigSyncKit `e31100998ed6d5c0a515eebc29ddb9acab3090ee`
- SwiftUIDownloads `750e8fdd3607c04a30a137c3428f6f1d334d6247`
- JapaneseLanguageTools `6cffbb79f95eb1a8f07766e0bafee8410a98f7b7`
- FaviconFinder `dba1692ad10917e5501f7da61c5d53290ac10e7e`
- LakeKit `4a60f068b20e2fb25055aad12f40fb1b7fd5c770`

The workflow checks each SHA and builds the real `LakeOfFireReader` target in Debug and Release. This specifically closes the gap left by #50/#53 component workflows, which parsed lifecycle Swift but did not compile it against Reader's sibling package graph.


## Consolidated sibling refresh

The first full target build reached LakeKit and found real Swift 6 failures in onboarding. The tuple has been refreshed to the conflict-resolved sibling heads rather than weakening the build:

- SwiftUtilities #1: `475973026ca1e953d016ff78e65c0be5bb4885d5` (green complete package + strict changed-file checks).
- JapaneseLanguageTools #1: `6cffbb79f95eb1a8f07766e0bafee8410a98f7b7` (green macOS/Linux priority-owner tests).
- LakeKit #9: `4a60f068b20e2fb25055aad12f40fb1b7fd5c770` (composes #5/#6/#7/#8; its retained workflows run independently).

The original failed Lake #59 run is retained as evidence that the previous Reader-main LakeKit selection did not compile under this Swift 6 tuple. The rerun tests the repaired dependency composition.
