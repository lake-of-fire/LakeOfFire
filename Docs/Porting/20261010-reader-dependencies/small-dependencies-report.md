# Small dependency forward-port audit — 2026-10-10

Publication note: final local LakeKit candidate is `29db685f7145182445324ac0d8aefbd58eb6f3c2`; the original unpublished `e02a984` candidate below had only its message amended to include `[skip ci]`. Its source tree is unchanged.

Owned: LakeImage, LakeKit, FaviconFinder, SwiftUtilities, Portal. Window: 2025-10-10 through 2026-10-10 inclusive. Original checkouts remained read-only. No builds, tests, benchmarks, generators, installs, native apps, CI dispatch, pushes or PR creation. Tests **not run by request**. Git diff whitespace check passed before commit.

## Outcome

Two source-proven LakeKit gaps are implemented in local commit e02a984 (full SHA recorded below), five files:

- **LakeKit/location-bar-progress-hide-ownership: genuinely missing → nested committed.** Main LocationBarProgressBar.updateProgress cancels old tasks but uses try? sleep followed by unconditional hide/reset. Replacement navigation progress cancels the previous nil-progress delay, which then hides its successor. Hotfix 356cff225d26620d8d2313106c3229d32a9a6fb5 supplies LocationBarProgressHide.run, selected by b93f882ebc5790a5f713c7c8f7bc1324da443a29. Port checks cancellation before and after injected sleep on MainActor and cancels on disappearance. Four runtime regression methods cover suspended noncooperative sleep, already canceled task, throwing sleep and ordinary completion. ReaderCore Reader/ReaderLocationBar.swift:1229 passes readerWebViewState.loadingProgress into the view. Existing main focus/accessibility behavior survives.
- **LakeKit/store-layout-toolchain-compatibility: genuinely missing → nested committed.** Hotfix 211a3b977a0f9977593807f0caae603b9bdfb697 and e5a8226f649a678165316dfef813fa8d0ebdaa5e remove failing ViewThatFits tuple inference and erase only the availability return boundary. Main retained the old shape. Root specs/HOTFIX-PORT.md:5672 records Xcode 27 rejection at macOS 15 deployment and historical successful compilation of adaptation; this corroborates provenance, not current execution. Port preserves wide→compact→vertical ordering, widths and spacing in purchaseOptionsGrid/purchaseOptionsCandidate. StoreView uses it for standard and qualifying-discount options. Current stronger onboarding MainActor loader and accessibility identifiers remain. No source-string test added for compiler behavior; current compilation and mounted resize checks remain open.

Documentation/Porting/lakekit-main-integration-20260929.md records exact boundary and unverified candidate. No dependency pins ported.

## Behavior and integration dispositions

**LakeImage: correctly ported, identical endpoint.** Five dated paths exist/equal. CustomDataLoader delegates network cancellation to Nuke; interceptor bytes synchronously complete before its no-op task returns. CustomImageProvider retains shared disk cache/pipeline. makeLakeImageRequest validates dimensions/scale, converts points to pixels, and keeps fit/fill/size in cache identity. View uses normal priority and cancel-on-disappear. Callers include LakeOfFire ReaderContentSourceIconImage, FeedCategoryImage, LibraryFeedView and ReaderCore NowPlayingBar; most do not opt into thumbnails. Tests include invalid inputs/cache identity and AppKit-only decode. Equality proves comparative parity, not app-pinned integration or platform execution.

**FaviconFinder: correctly ported, stronger upstream ownership.** HTML/manifest finders carry effective final document URL and surviving headers from documentTask through relative links, manifest fetch and icon resolution. FaviconRequestPolicy bounds bodies to 2 MiB and redirects to ten, validates HTTP URLs, strips custom credentials across origins while preserving harmless negotiation headers, and never restores stripped credentials after returning to original origin. Apple disables automatic redirects and cancels owned byte task; Linux uses bounded AsyncHTTPClient with per-chain shutdown. ICOFaviconFinder requests actual fallback destination and stores matching request headers. Equal FaviconURL.httpHeaders reaches Favicon.init(url:) transport. Main policy/loopback tests replace hotfix coverage; gated live-network tests are not credited as execution. LakeOfFire LibraryFeedView.refreshIcon selects source.absoluteString then displays via LakeImage, dropping discovered headers in URL-only persistence. That caller currently supplies no custom headers. Authenticated persistence/display remains an external integration gate; library API parity alone does not close it.

**SwiftUtilities: correctly ported/stronger main.** StableHash source/tests equal: consecutive-string overload intentionally hashes joined UTF-8 bytes; hex helper retains uppercase/minimum two digits. ReaderCore callers in YomitanReadinessResolver/ReaderModeContentProcessor own delimiter/width formatting; those policies were not replaced. WindowAccessor.Coordinator is stronger in main: binding/report generations reject stale queued reports after replacement. Callers include LakeOfFire LibraryCategoriesView and ReaderCore navigation. Hotfix emptied ManabiSystemUIFontCSS; main retained helper has no callers found in inspected ReaderCore/LakeOfFire source. Retain upstream utility; no useful dated missing contract requires deletion.

**LakeKit sessions: correctly ported/relocated.** Equal SessionCredentialRepository alternates canonical slots before authentication publication, retains durable credentials on failure, cleans ancillary logout records before current slot, and resolves latest revision/recordID. Main Session+EphemeralTesting.swift preserves hotfix fixture API outside Sessions.swift, adds delay control, and dedicated EphemeralSessionPortTests cover stores, boundaries, replacement and logout. Main persistence tests preserve durable roundtrip/migration/write/logout failures and authorization generations. Original hotfix dirty credential repository/session/tests are WIP only and untouched.

**LakeKit share sheet: stronger main.** ActivityItem.presentationID, ShareSheetPresentationState.Token and native ownership fence queued presentation, replacement, completion, teardown and dismissal on iOS/macOS. Completion reads current binding ID, so old callbacks cannot clear a successor written before SwiftUI update. Main state/native tests cover attachment, queued work, teardown and stale completion. Do not overwrite this with hotfix previous-item repair.

**LakeKit picker/search and equal UI: correctly ported.** FitWidthSegmentedPicker handles invalid/disabled choices, callbacks instead of forcing controlled binding, reselection and no-op native updates. ReaderCore lookup/settings callers use it. EnhancedSearchable retains changeID/current-text filtering, replacement/closing cancellation and macOS policy; live lookup/destination callers found. Other equal button/stack/presentation/translation/download utility paths accounted below. Translation positional IDs do not provide generation authority by themselves; higher-layer inline batch ownership is outside this slice. Equal file-export task/cleanup source does not prove all mounted replacement paths.

**LakeKit background/cache/referral: preserve main.** Main BackgroundWorker loops on Thread.current.isCancelled, avoiding hotfix weak-self/current-thread-property lifetime race. Hotfix two worker tests absent as separate file; main stop-before-start coverage exists, but start/stop execution coverage is thinner. No source regression proved. Three historical LRUCache files and old popover template are absent at both endpoints. Live PersistedLRUCacheExports retains external SQLite alias; main revision requirement is intentional graph resolution, no stale pins copied. ReferralCodeUsage.create source equal, adds row then refreshes metadata inside RealmBackgroundActor.asyncWrite; hotfix test checks BigSync journal while main test checks explicit metadata. Durable sync behavior depends on separate BigSync/configuration owner; equality is not runtime journal proof.

**LakeKit onboarding: intentionally stronger main.** Main splits deterministic grain math and owns highlighted product loading on MainActor, storing non-Sendable StoreHelper there and suppressing canceled publication. Skip-button shape was deliberately rebuilt in compiler integration. Preserve newer implementation over hotfix style helper.

**Portal: exact endpoint parity, inactive in inspected production graph.** 294 dated commits/298 paths; source/target same commit. 110 endpoint paths exist; 188 renamed/deleted paths absent at both. Manifest emits PortalTransitions, PortalHeaders, _PortalPrivate/PortalPrivate, excludes examples and owns three test targets. Inspected completion compatibility, namespace/group identity and header runtime calculations/tests. No Portal product/caller found in root Project/Tuist graph, LakeOfFire/LakeKit manifests or ReaderCore/LakeOfFire production source search. Checkout presence does not prove reachability. No port gap; package UI execution unverified.

## Corrected nested MeCab discovery

Root proved 37f46ddb913731d2a8aa356053597cf913aa2dd5 is a **tree**, not gitlink/commit. Old .gitmodules entry is stale: Sources/mecab is vendored ManabiMeCab parent source. Git under uninitialized child silently resolved parent, so inventory mecab target 98b65110cef2823fe83bb002506e437f8461128c was invalid as engine target. No owned nested dependency exists. Root independently fetched engine master 4eb36c8b as discovery evidence; that cannot establish ancestry against a parent tree. Parent ManabiMeCab explicitly excluded and unedited. Remove false repo from totals; no engine port/equivalence claim.

## Coverage and remaining gates

Deterministic pass: frozen endpoints → 27 differing dated paths → 345 equal paths → relocated owners, consumers and test/config distinctions. This is 372 paths across five valid repos, including 192 absent-at-both historical paths. Per-path ledger below compares frozen main before implementation. Dated provenance is in each Repository-commits.txt; these are finite walks, not a claim about unrelated older differences.

Supplemental shuffle uses Python random.Random(20261010).shuffle on original ordered clusters: LakeKit/session-credentials, LakeKit/store-layout, LakeKit/share-sheet, LakeKit/location-progress, LakeKit/segmented-search, LakeKit/cache-and-small-ui, FaviconFinder/redirect-origin, FaviconFinder/final-download, LakeImage/request-and-loader, SwiftUtilities/window-and-hash, Portal/product-reachability, mecab/provenance.

Recorded order/results: store-layout (tuple gap); window-and-hash (retain stronger generations); redirect-origin (stronger policy); request-and-loader (exact equality); final-download (URL-only consumer limit); share-sheet (main ownership); product-reachability (no caller); provenance (false repo corrected); segmented-search (callbacks/no-op retained); session-credentials (relocated API found); location-progress (helper wired/runtime source); cache-and-small-ui (retired files distinguished).

New progress test belongs to existing SwiftPM LakeKitTests default source membership. Reader root Project.swift:826-827 explicitly selects only LakeKitTests.swift and SessionCredentialPersistenceTests.swift, so new regression is not selected by root test target. Current compilation, test execution, root integration and iOS/macOS mounted checks remain open. Store adaptation needs current-toolchain build and mounted layout, not source assertions.

All differing dated paths have comparative dispositions. Every equal helper's external callers, BigSync journal runtime, authenticated favicon persistence/display and mounted UI behavior are not closed. Original dirty WIP excluded. Consumer reachability was read in current main checkout, not claimed as a published compatible root tuple. No unreviewed differing dated path remains; excluded parent source is not counted.

## Exact endpoints and pending PRs

| Repo | Source | Main target | Dated commits / paths |
|---|---|---|---|
| LakeImage | 3270761611fa85b4b6129227b4adf2bbda4be5a0 | 3270761611fa85b4b6129227b4adf2bbda4be5a0 | 11 / 5 |
| LakeKit | a5db41e0ca326cb0cbe0094dcce9fcdff2160a6b | ce5732052d1480329b4b1c47f1440877dedf0e41 | 126 / 50 |
| FaviconFinder | 9fdaeba2c01bd9692d79029b5179205eac7276bc | 27f81e1b66d3934890f7e7858c803cf0d27a6113 | 9 / 14 |
| SwiftUtilities | f437c7d06fc631cd7a67731279411c417cdf8077 | 9df24a7809f5b681c8480ba7ef681335977f0fc5 | 5 / 5 |
| Portal | 424c0dc1b7bb327491b573d74f1ca8253df834e8 | 424c0dc1b7bb327491b573d74f1ca8253df834e8 | 294 / 298 |

All five frozen prs arrays are empty; no pending upstream PR changes duplicate these ports. All repositories are non-shallow. LakeKit main includes [PR #9](https://github.com/lake-of-fire/LakeKit/pull/9), composing [#5](https://github.com/lake-of-fire/LakeKit/pull/5), [#6](https://github.com/lake-of-fire/LakeKit/pull/6), [#7](https://github.com/lake-of-fire/LakeKit/pull/7), [#8](https://github.com/lake-of-fire/LakeKit/pull/8).
Local implementation SHA: e02a984fab5bbf0c2007ee7d826741f76e8f2783

## Per-path ledger

### LakeImage

| Path | Kind | Disposition |
|---|---|---|
| .gitignore | docs/config/generated/assets/example | endpoint equal / comparative covered |
| Package.resolved | docs/config/generated/assets/example | endpoint equal / comparative covered |
| Package.swift | docs/config/generated/assets/example | endpoint equal / comparative covered |
| Sources/LakeImage/LakeImage.swift | source | endpoint equal / comparative covered |
| Tests/LakeImageTests/LakeImageTests.swift | test | endpoint equal / comparative covered |

### LakeKit

| Path | Kind | Disposition |
|---|---|---|
| .gitignore | docs/config/generated/assets/example | endpoint equal / comparative covered |
| Package.resolved | docs/config/generated/assets/example | intentional graph/pin divergence / not ported |
| Package.swift | docs/config/generated/assets/example | intentional graph/pin divergence / not ported |
| Sources/LakeKit/BackgroundWorker.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/Caching/LRUCache/CacheDirectory.swift | source | intentionally retired / absent at both |
| Sources/LakeKit/Caching/LRUCache/LRUFileCache.swift | source | intentionally retired / absent at both |
| Sources/LakeKit/Caching/LRUCache/LRUSQLiteCache.swift | source | intentionally retired / absent at both |
| Sources/LakeKit/Caching/PersistedLRUCacheExports.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/ClearBorderedButtonStyle.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/CollectionView.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/DismissButton.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/EmptyStateBoxView.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/FitWidthSegmentedPicker.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/FrameTag.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/LocationBar.swift | source | genuinely missing / focused port committed |
| Sources/LakeKit/LocationBarProgressHide.swift | source | genuinely missing / focused port committed |
| Sources/LakeKit/Logger.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Onboarding/OnboardingFreeModeView.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Onboarding/OnboardingSheet.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/PopoversTemplates+RoundedContainer.swift | source | intentionally retired / absent at both |
| Sources/LakeKit/PrimaryActionControlStyles.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Search/EnhancedSearchable.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/SessionCredentialRepository.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Sessions.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/ShareLink/DefaultShareLinkLabel.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/ShareLink/ShareSheet.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/ShareLink/Transferable.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/SplitViewAccessor.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/SplitViewModel.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/StackUI/StackList.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/StackUI/StackListGroupBoxStyle.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/StackUI/StackSection.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/StackUI/StackSectionList.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/StackUI/SteppedInstructionGroupBoxStyle.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Store/PurchaseOptionView.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Store/ReferralCode.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Store/StoreView.swift | source | genuinely missing / focused port committed |
| Sources/LakeKit/Store/StoreViewModel.swift | source | covered / stronger or relocated main |
| Sources/LakeKit/Tip+Status.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/Transitions/WheelScroll.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/TranslationRequest.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/UserInterfaceIdiom.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/ViewModifiers/FileDownloadExporterModifier.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/ZIPArchive.swift | source | endpoint equal / comparative covered |
| Sources/LakeKit/iCloud.swift | source | endpoint equal / comparative covered |
| Tests/LakeKitTests/BackgroundWorkerTests.swift | test | test thinner / no source gap proved |
| Tests/LakeKitTests/FitWidthSegmentedPickerTests.swift | test | endpoint equal / comparative covered |
| Tests/LakeKitTests/LakeKitTests.swift | test | runtime tests adapted / journal gate separate |
| Tests/LakeKitTests/LocationBarProgressHideTests.swift | test | genuinely missing / focused port committed |
| Tests/LakeKitTests/SessionCredentialPersistenceTests.swift | test | covered / stronger or relocated main |

### FaviconFinder

| Path | Kind | Disposition |
|---|---|---|
| .gitignore | docs/config/generated/assets/example | config/runtime tests adapted to stronger policy; not ported |
| Package.swift | docs/config/generated/assets/example | config/runtime tests adapted to stronger policy; not ported |
| Package@swift-6.0.swift | docs/config/generated/assets/example | config/runtime tests adapted to stronger policy; not ported |
| Sources/FaviconFinder/Finders/HTMLFaviconFinder.swift | source | covered / stronger or relocated main |
| Sources/FaviconFinder/Finders/ICOFaviconFinder.swift | source | covered / stronger or relocated main |
| Sources/FaviconFinder/Finders/WebApplicationManifestFaviconFinder.swift | source | covered / stronger or relocated main |
| Sources/FaviconFinder/Toolbox/FaviconURLSession.swift | source | covered / stronger or relocated main |
| Sources/FaviconFinder/Types/Favicon.swift | source | endpoint equal / comparative covered |
| Sources/FaviconFinder/Types/FaviconURL.swift | source | endpoint equal / comparative covered |
| Tests/FaviconFinderTests/FaviconFinderTests.swift | test | config/runtime tests adapted to stronger policy; not ported |
| Tests/FaviconFinderTests/FaviconURLTests.swift | test | config/runtime tests adapted to stronger policy; not ported |
| iOSFaviconFinderExample/iOSFaviconFinderExample/ContentView.swift | docs/config/generated/assets/example | endpoint equal / comparative covered |
| macOSFaviconFinderExample/macOSFaviconFinderExample.xcodeproj/project.pbxproj | docs/config/generated/assets/example | endpoint equal / comparative covered |
| macOSFaviconFinderExample/macOSFaviconFinderExample/ContentView.swift | docs/config/generated/assets/example | endpoint equal / comparative covered |

### SwiftUtilities

| Path | Kind | Disposition |
|---|---|---|
| .gitignore | docs/config/generated/assets/example | endpoint equal / comparative covered |
| Sources/SwiftUtilities/ManabiSystemUIFontCSS.swift | source | intentional retained main utility / no caller found |
| Sources/SwiftUtilities/NSViewRepresentable+WindowAccessor.swift | source | covered / stronger or relocated main |
| Sources/SwiftUtilities/StableHash.swift | source | endpoint equal / comparative covered |
| Tests/SwiftUtilitiesTests/SwiftUtilitiesTests.swift | test | endpoint equal / comparative covered |

### Portal

| Path | Kind | Disposition |
|---|---|---|
| .claude/settings.local.json | docs/config/generated/assets/example | intentionally retired / absent at both |
| .githooks/pre-commit | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/FUNDING.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/ISSUE_TEMPLATE/bug_report.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/ISSUE_TEMPLATE/config.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/ISSUE_TEMPLATE/feature_request.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows-disabled/claude-code-review.yml | docs/config/generated/assets/example | intentionally retired / absent at both |
| .github/workflows-disabled/swift.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows/build.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows/claude-code-review.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows/claude.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows/pre-release.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows/release.yml | docs/config/generated/assets/example | intentionally retired / absent at both |
| .github/workflows/swift-lint.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .github/workflows/tests.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .gitignore | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .gitmodules | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .header-template | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/examples/example1.gif | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/icon/icon.icon/Assets/Grid.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/icon/icon.icon/Assets/vga-kinetic-export.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/icon/icon.icon/Assets/vga-kinetic-export2.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/icon/icon.icon/icon.json | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/icon/icon.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/scripts/add-headers.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/scripts/fix-header-spacing.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/scripts/run-swiftlint.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/scripts/setup-hooks.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| .resources/templates/.header-template | docs/config/generated/assets/example | intentionally retired / absent at both |
| .scripts/add-headers.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .scripts/fix-header-spacing.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .scripts/run-swiftlint.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .scripts/setup-hooks.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .swiftlint.yml | docs/config/generated/assets/example | endpoint equal / comparative covered |
| .swiftpm/xcode/xcshareddata/xcschemes/Portal 1.xcscheme | docs/config/generated/assets/example | intentionally retired / absent at both |
| .swiftpm/xcode/xcshareddata/xcschemes/Portal.xcscheme | docs/config/generated/assets/example | intentionally retired / absent at both |
| CODE_OF_CONDUCT.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| CONTRIBUTING.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| CompilerCrashReproducer | docs/config/generated/assets/example | intentionally retired / absent at both |
| Package.resolved | docs/config/generated/assets/example | intentionally retired / absent at both |
| Package.swift | docs/config/generated/assets/example | endpoint equal / comparative covered |
| README.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| ROADMAP.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/examples/example1.gif | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/icon/icon.icon/Assets/Grid.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/icon/icon.icon/Assets/vga-kinetic-export.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/icon/icon.icon/Assets/vga-kinetic-export2.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/icon/icon.icon/icon.json | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/icon/icon.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/scripts/add-headers.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/scripts/fix-header-spacing.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/scripts/run-swiftlint.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/scripts/setup-hooks.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Resources/templates/.header-template | docs/config/generated/assets/example | intentionally retired / absent at both |
| Scripts/add-headers.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Scripts/fix-header-spacing.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Scripts/run-swiftlint.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Scripts/setup-hooks.sh | docs/config/generated/assets/example | intentionally retired / absent at both |
| Sources/Portal/.swift | source | intentionally retired / absent at both |
| Sources/Portal/AnchorKey.swift | source | intentionally retired / absent at both |
| Sources/Portal/AnimatedPortalLayer.swift | source | intentionally retired / absent at both |
| Sources/Portal/CrossModel.swift | source | endpoint equal / comparative covered |
| Sources/Portal/Examples/AnimatedLayer.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExampleCardGrid.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExampleComparison.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExampleList.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExampleStaticID.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExample_CardGrid.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExample_Comparison.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExample_List.swift | source | intentionally retired / absent at both |
| Sources/Portal/Examples/PortalExample_StaticID.swift | source | intentionally retired / absent at both |
| Sources/Portal/Helpers/HiddenStatusHostingController.swift | source | intentionally retired / absent at both |
| Sources/Portal/PassThroughWindow.swift | source | intentionally retired / absent at both |
| Sources/Portal/Portal.swift | source | endpoint equal / comparative covered |
| Sources/Portal/PortalConstants.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalContainer.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalDebugOverlaysKey.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalEnvironment.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalInfo.swift | source | endpoint equal / comparative covered |
| Sources/Portal/PortalLayerView.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalLogs.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalTransition.swift | source | intentionally retired / absent at both |
| Sources/Portal/PortalTransitionConfig.swift | source | endpoint equal / comparative covered |
| Sources/Portal/PortalTransitionModifiersDirect.swift | source | intentionally retired / absent at both |
| Sources/Portal/Transitions/ConditionalPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/Portal/Transitions/GroupIDPortalTransitionModifier.swift | source | endpoint equal / comparative covered |
| Sources/Portal/Transitions/GroupItemPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/Portal/Transitions/MultiIDPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/Portal/Transitions/MultiItemPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/Portal/Transitions/OptionalPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/AccessoryFlowingKey.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/AnchorKey.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/DebugOverlayIndicator.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/Examples.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/Examples/FlowingHeaderExampleNoAccessory.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/Examples/FlowingHeaderExampleTitleOnly.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/Examples/FlowingHeaderExampleWithAccessory.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderAdvancedExamples.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderAnchorSupport.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderBasicExamples.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderCalculations.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderConfig.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderConstants.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderContent.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderDebugOverlaysKey.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderDestination.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderExample.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderLogs.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderMockData.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderSupport.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderTokens.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderTransition.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/FlowingHeaderView.swift | source | intentionally retired / absent at both |
| Sources/PortalFlowingHeader/TitleProgressKey.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/AccessoryFlowingKey.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/AnchorKey.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/DebugOverlayIndicator.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/Examples/FlowingHeaderExampleNoAccessory.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/Examples/FlowingHeaderExampleTitleOnly.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/Examples/FlowingHeaderExampleWithAccessory.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/Examples/PortalHeaderExampleNoAccessory.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/Examples/PortalHeaderExampleTitleOnly.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/Examples/PortalHeaderExampleWithAccessory.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/FlowingHeaderCalculations.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/FlowingHeaderContent.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/FlowingHeaderDebugOverlaysKey.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/FlowingHeaderDestination.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/FlowingHeaderLogs.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/FlowingHeaderTokens.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/FlowingHeaderView.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/PortalHeaderCalculations.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/PortalHeaderContent.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/PortalHeaderDebugOverlaysKey.swift | source | intentionally retired / absent at both |
| Sources/PortalHeaders/PortalHeaderDebugStyle.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/PortalHeaderDestination.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/PortalHeaderLogs.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/PortalHeaderTokens.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/PortalHeaderView.swift | source | endpoint equal / comparative covered |
| Sources/PortalHeaders/TitleProgressKey.swift | source | endpoint equal / comparative covered |
| Sources/PortalPrivate/AnimatedLayer.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/AnimatedLayer.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExampleCardGrid.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExampleComparison.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExampleList.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExampleMultiItem.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExampleStaticID.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExample_CardGrid.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExample_Comparison.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExample_List.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExample_MultiItem.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalExample_StaticID.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalPrivateExampleCardGrid.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalPrivateExampleComparison.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalPrivateExampleList.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/Examples/PortalPrivateExampleStaticID.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/PortalPrivate.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/PortalPrivateExample.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/PortalPrivateExampleApp.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/PortalPrivateExampleNoSheet.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/PortalPrivateExampleNoSheetView.swift | source | intentionally retired / absent at both |
| Sources/PortalPrivate/README.md | source | intentionally retired / absent at both |
| Sources/PortalTransitions/AnchorKey.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/AnimatedLayers/AnimatedItemPortalLayer.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/AnimatedLayers/AnimatedPortalLayer.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/AnimatedPortalLayer.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Core/AnchorKey.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Core/CrossModel.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Core/PortalAnimationCompatibility.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Core/PortalConstants.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Core/PortalInfo.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Core/PortalKey.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/CrossModel.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Examples/AnimatedLayer.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Examples/CompilerCrashReproducer.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Examples/PortalExampleCardGrid.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Examples/PortalExampleComparison.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Examples/PortalExampleGridCarousel.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Examples/PortalExampleList.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Examples/PortalExampleStaticID.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Helpers/HiddenStatusHostingController.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Modifiers/ConditionalPortalTransitionModifier.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Modifiers/GroupIDPortalTransitionModifier.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Modifiers/GroupItemPortalTransitionModifier.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Modifiers/OptionalPortalTransitionModifier.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/PassThroughWindow.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Portal.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalConstants.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalContainer.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalCorners.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalDebugOverlaysKey.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalFade.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalInfo.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalLayerView.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalLogs.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalRemoveTransition.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalTransitionConfig.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/PortalTransitionDebugStyle.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Styling/PortalCorners.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Styling/PortalRemoveTransition.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Styling/PortalTransitionDebugStyle.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Transitions/ConditionalPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Transitions/GroupIDPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Transitions/GroupItemPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Transitions/OptionalPortalTransitionModifier.swift | source | intentionally retired / absent at both |
| Sources/PortalTransitions/Utilities/HiddenStatusHostingController.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Utilities/PortalLogs.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Views/PassThroughWindow.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Views/Portal.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Views/PortalContainer.swift | source | endpoint equal / comparative covered |
| Sources/PortalTransitions/Views/PortalLayerView.swift | source | endpoint equal / comparative covered |
| Sources/PortalView/PortalView.swift | source | endpoint equal / comparative covered |
| Sources/PortalView/UIPortalViewExample.swift | source | intentionally retired / absent at both |
| Sources/UIPortalBridge/PortalView.swift | source | endpoint equal / comparative covered |
| Sources/UIPortalBridge/UIPortalView.swift | source | endpoint equal / comparative covered |
| Sources/_PortalMirror/PortalPrivateExampleApp.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/PortalPrivateExampleNoSheetView.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/Examples/AnimatedLayer.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/Examples/PortalExampleMultiItem.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/Examples/PortalPrivateExampleCardGrid.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/Examples/PortalPrivateExampleComparison.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/Examples/PortalPrivateExampleList.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/Examples/PortalPrivateExampleStaticID.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/Transitions/PortalPrivate.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/View/PortalView.swift | source | intentionally retired / absent at both |
| Sources/_PortalMirror/View/UIPortalViewExample.swift | source | intentionally retired / absent at both |
| Sources/_PortalPrivate/PortalPrivateExampleApp.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/PortalPrivateExampleNoSheetView.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/Examples/AnimatedLayer.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/Examples/PortalExampleMultiItem.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/Examples/PortalPrivateExampleCardGrid.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/Examples/PortalPrivateExampleComparison.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/Examples/PortalPrivateExampleList.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/Examples/PortalPrivateExampleStaticID.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/Transitions/PortalPrivate.swift | source | endpoint equal / comparative covered |
| Sources/_PortalPrivate/View/PortalView.swift | source | intentionally retired / absent at both |
| Sources/_PortalPrivate/View/UIPortalViewExample.swift | source | endpoint equal / comparative covered |
| Tests/PortalFlowingHeaderTests/FlowingHeaderAnchorTests.swift | test | intentionally retired / absent at both |
| Tests/PortalFlowingHeaderTests/FlowingHeaderCalculationsTests.swift | test | intentionally retired / absent at both |
| Tests/PortalFlowingHeaderTests/FlowingHeaderTests.swift | test | intentionally retired / absent at both |
| Tests/PortalHeadersTests/FlowingHeaderAnchorTests.swift | test | intentionally retired / absent at both |
| Tests/PortalHeadersTests/FlowingHeaderCalculationsTests.swift | test | intentionally retired / absent at both |
| Tests/PortalHeadersTests/FlowingHeaderTests.swift | test | intentionally retired / absent at both |
| Tests/PortalHeadersTests/PortalHeaderAnchorTests.swift | test | endpoint equal / comparative covered |
| Tests/PortalHeadersTests/PortalHeaderCalculationsTests.swift | test | endpoint equal / comparative covered |
| Tests/PortalHeadersTests/PortalHeaderTests.swift | test | endpoint equal / comparative covered |
| Tests/PortalPrivateTests/PortalPrivateTests.swift | test | intentionally retired / absent at both |
| Tests/PortalTests/PortalCoreTests.swift | test | intentionally retired / absent at both |
| Tests/PortalTests/PortalPrivateTests.swift | test | intentionally retired / absent at both |
| Tests/PortalTests/SheetShowTests.swift | test | intentionally retired / absent at both |
| Tests/PortalTransitionsTests/PortalCoreTests.swift | test | endpoint equal / comparative covered |
| Tests/PortalViewTests/PortalViewTests.swift | test | intentionally retired / absent at both |
| Tests/_PortalMirrorTests/PortalPrivateTests.swift | test | intentionally retired / absent at both |
| Tests/_PortalMirrorTests/PortalViewTests.swift | test | intentionally retired / absent at both |
| Tests/_PortalPrivateTests/PortalPrivateTests.swift | test | endpoint equal / comparative covered |
| Tests/_PortalPrivateTests/PortalViewTests.swift | test | endpoint equal / comparative covered |
| assets/icon.icon/Assets/grid.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| assets/icon.icon/Assets/vga-kinetic-export.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| assets/icon.icon/Assets/vga-kinetic-export2.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| assets/icon.icon/icon.json | docs/config/generated/assets/example | intentionally retired / absent at both |
| assets/icon.png | docs/config/generated/assets/example | intentionally retired / absent at both |
| docs/PortalHeaders/BasicUsage.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalHeaders/DebugOverlays.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalHeaders/SnappingBehavior.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalPrivate.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/AnimatedLayers.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/AnimationOptions.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/BasicUsage.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/DebugOverlays.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/GroupAnimations.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/HowItWorks.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/ItemBasedAnimatedLayers.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/PortalTransitions/TransferringPortals.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| docs/README.md | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/examples/example1.gif | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/icon/icon.icon/Assets/Grid.png | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/icon/icon.icon/Assets/vga-kinetic-export.png | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/icon/icon.icon/Assets/vga-kinetic-export2.png | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/icon/icon.icon/icon.json | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/icon/icon.png | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/scripts/add-headers.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/scripts/fix-header-spacing.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/scripts/run-swiftlint.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/scripts/setup-hooks.sh | docs/config/generated/assets/example | endpoint equal / comparative covered |
| resources/templates/.header-template | docs/config/generated/assets/example | endpoint equal / comparative covered |
| wiki | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/Animations.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/Debugging.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/FlowingHeader.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/Home.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/How-Portal-Works.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/How-to-Install.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/Portal-Groups.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/PortalMirror.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/PortalPrivate.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/PortalView.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/TIMING_REQUIREMENTS.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/Usage.md | docs/config/generated/assets/example | intentionally retired / absent at both |
| wiki updates/_Sidebar.md | docs/config/generated/assets/example | intentionally retired / absent at both |
