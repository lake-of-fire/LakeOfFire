import SwiftUI
import UniformTypeIdentifiers
import WebKit
import RealmSwift
#if os(macOS)
import AppKit
import Darwin
#endif
import LakeOfFireContent
import LakeOfFireCore
import LakeOfFireFiles
import LakeOfFireReader
import SwiftCloudDrive
import SwiftUIWebView

private func harnessLog(_ message: String) {
    fputs("[EbookRendererHarness] \(message)\n", stderr)
    fflush(stderr)
}

private func harnessRootURL() -> URL {
    let baseURL = FileManager.default.temporaryDirectory
    return baseURL
        .appendingPathComponent("EbookRendererHarness", isDirectory: true)
}

private func harnessStorageRootURL() -> URL {
    harnessRootURL()
        .appendingPathComponent("ReaderFiles", isDirectory: true)
}

private func harnessRealmRootURL() -> URL {
    harnessRootURL()
        .appendingPathComponent("Realms", isDirectory: true)
}

private func makeHarnessReaderRealmConfiguration(rootURL: URL) -> Realm.Configuration {
    var config = Realm.Configuration()
    config.fileURL = rootURL.appendingPathComponent("harness-reader.realm")
    config.schemaVersion = 239
    config.deleteRealmIfMigrationNeeded = true
    config.objectTypes = [
        ArticleReadingProgress.self,
        Bookmark.self,
        ContentFile.self,
        ContentPackageFile.self,
        HistoryRecord.self,
        OPDSCatalog.self,
        ReadingSession.self,
    ]
    return config
}

private func makeHarnessSharedRealmConfiguration(rootURL: URL) -> Realm.Configuration {
    var config = DefaultRealmConfiguration.configuration
    config.fileURL = rootURL.appendingPathComponent("harness-shared.realm")
    config.deleteRealmIfMigrationNeeded = true
    return config
}

private struct HarnessEventRecord: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let name: String
    let payload: String
}

private enum HarnessViewportPreset: String, CaseIterable, Identifiable {
    case iphonePortrait
    case iphoneLandscape
    case ipadPortrait
    case ipadLandscape
    case macBook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iphonePortrait: "iPhone Portrait"
        case .iphoneLandscape: "iPhone Landscape"
        case .ipadPortrait: "iPad Portrait"
        case .ipadLandscape: "iPad Landscape"
        case .macBook: "MacBook"
        }
    }

    var size: CGSize {
        switch self {
        case .iphonePortrait: CGSize(width: 390, height: 844)
        case .iphoneLandscape: CGSize(width: 844, height: 390)
        case .ipadPortrait: CGSize(width: 820, height: 1180)
        case .ipadLandscape: CGSize(width: 1180, height: 820)
        case .macBook: CGSize(width: 1280, height: 900)
        }
    }
}

private enum HarnessWritingDirection: String, CaseIterable, Identifiable {
    case original
    case horizontal
    case vertical

    var id: String { rawValue }
}

private enum HarnessDumpKind: String, CaseIterable, Identifiable {
    case pagination
    case renderer

    var id: String { rawValue }
}

private struct HarnessCLIOptions {
    let bookURL: URL?
    let smokeTest: Bool
    let smokeTimeoutSeconds: Double

    static let current = parse(CommandLine.arguments)

    private static func parse(_ arguments: [String]) -> HarnessCLIOptions {
        var bookURL: URL?
        var smokeTest = false
        var smokeTimeoutSeconds = 25.0

        for argument in arguments.dropFirst() {
            if argument == "--smoke-test" {
                smokeTest = true
                continue
            }
            if let rawValue = argument.split(separator: "=", maxSplits: 1).map(String.init).last,
               argument.hasPrefix("--smoke-timeout="),
               let parsed = Double(rawValue),
               parsed > 0 {
                smokeTimeoutSeconds = parsed
                continue
            }
            if !argument.hasPrefix("--"), bookURL == nil {
                bookURL = URL(fileURLWithPath: argument)
            }
        }

        return HarnessCLIOptions(
            bookURL: bookURL,
            smokeTest: smokeTest,
            smokeTimeoutSeconds: smokeTimeoutSeconds
        )
    }
}

@MainActor
private final class EbookRendererHarnessModel: ObservableObject {
    private static var didBootstrapFileManagers = false

    let cliOptions = HarnessCLIOptions.current
    let navigator = WebViewNavigator()
    let scriptCaller = WebViewScriptCaller()
    let ebookURLSchemeHandler = EbookURLSchemeHandler()
    let readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()

    @Published var webViewState: WebViewState = .empty
    @Published var hideNavigationDueToScroll = false
    @Published var textSelection: String?
    @Published var loadedBookURL: URL?
    @Published var loadedBookDisplayName: String?
    @Published var isImportingBook = false
    @Published var latestDump = ""
    @Published var latestError: String?
    @Published var events: [HarnessEventRecord] = []
    @Published var viewportPreset: HarnessViewportPreset = .ipadLandscape
    @Published var paginationMode: WebViewPaginationMode = .leftToRight
    @Published var isPaginationEnabled = true
    @Published var usesViewLength = true
    @Published var explicitPageLength: Double = 0
    @Published var pageGap: Double = 24
    @Published var darkModeSetting: DarkModeSetting = .system
    @Published var lightModeTheme: LightModeTheme = .white
    @Published var darkModeTheme: DarkModeTheme = .black
    @Published var writingDirection: HarnessWritingDirection = .original
    @Published var jumpTarget = ""
    @Published var selectedDumpKind: HarnessDumpKind = .pagination
    @Published var lastKnownCFI = ""
    @Published var lastKnownFractionalCompletion: Double = 0
    @Published var currentContentPageURL: String?
    @Published var isBootstrapReady = false

    private var hasLoadedLastPosition = false
    private var autoImportArgumentHandled = false
    private var didStartSmokeTest = false
    private var smokeWebViewState: WebViewState = .empty

    init() {
        if cliOptions.smokeTest {
            // Avoid applying runtime pagination to about:blank during smoke bootstrap.
            isPaginationEnabled = false
        }
    }

    private var activeWebViewState: WebViewState {
        cliOptions.smokeTest ? smokeWebViewState : webViewState
    }

    func currentWebViewStateForSmokeBinding() -> WebViewState {
        smokeWebViewState
    }

    func updateWebViewStateForSmokeBinding(_ state: WebViewState) {
        smokeWebViewState = state
    }

    var paginationConfiguration: WebViewPaginationConfiguration {
        let storedPageLength = usesViewLength ? 0 : explicitPageLength
        return WebViewPaginationConfiguration(
            mode: isPaginationEnabled ? paginationMode : .unpaginated,
            storedPageLength: CGFloat(storedPageLength),
            gapBetweenPages: CGFloat(pageGap),
            behavesLikeColumns: true,
            layoutSize: viewportPreset.size
        )
    }

    var messageHandlers: WebViewMessageHandlers {
        WebViewMessageHandlers([
            ("ebookViewerInitialized", { [weak self] message in
                await self?.handleMessage(named: "ebookViewerInitialized", message: message)
            }),
            ("ebookViewerLoaded", { [weak self] message in
                await self?.handleMessage(named: "ebookViewerLoaded", message: message)
            }),
            ("pageMetadataUpdated", { [weak self] message in
                await self?.handleMessage(named: "pageMetadataUpdated", message: message)
            }),
            ("updateCurrentContentPage", { [weak self] message in
                await self?.handleMessage(named: "updateCurrentContentPage", message: message)
            }),
            ("updateReadingProgress", { [weak self] message in
                await self?.handleMessage(named: "updateReadingProgress", message: message)
            }),
            ("ebookNavigationVisibility", { [weak self] message in
                await self?.handleMessage(named: "ebookNavigationVisibility", message: message)
            }),
            ("finishedReadingBook", { [weak self] message in
                await self?.handleMessage(named: "finishedReadingBook", message: message)
            }),
            ("startOver", { [weak self] message in
                await self?.handleMessage(named: "startOver", message: message)
            }),
            ("ebookCacheWarmerLoadedSection", { [weak self] message in
                await self?.handleMessage(named: "ebookCacheWarmerLoadedSection", message: message)
            }),
            ("ebookCacheWarmerReadyToLoadNextSection", { [weak self] message in
                await self?.handleMessage(named: "ebookCacheWarmerReadyToLoadNextSection", message: message)
            }),
            ("readerOnError", { [weak self] message in
                await self?.handleMessage(named: "readerOnError", message: message)
            }),
            ("print", { [weak self] message in
                await self?.handleMessage(named: "print", message: message)
            }),
        ])
    }

    func bootstrapIfNeeded() async {
        guard !Self.didBootstrapFileManagers else { return }
        Self.didBootstrapFileManagers = true
        harnessLog("bootstrap.begin")

        if cliOptions.smokeTest {
            do {
                let rootURL = harnessRootURL()
                if FileManager.default.fileExists(atPath: rootURL.path) {
                    try FileManager.default.removeItem(at: rootURL)
                    harnessLog("bootstrap.smoke.reset root=\(rootURL.path)")
                }
            } catch {
                latestError = "Smoke bootstrap reset failed: \(error.localizedDescription)"
                appendEvent("bootstrap.reset.error", payload: latestError ?? "unknown error")
                harnessLog("bootstrap.reset.error \(latestError ?? "unknown error")")
            }
        }

        let realmRootURL = harnessRealmRootURL()
        do {
            try FileManager.default.createDirectory(at: realmRootURL, withIntermediateDirectories: true)
            let readerRealmConfiguration = makeHarnessReaderRealmConfiguration(rootURL: realmRootURL)
            let sharedRealmConfiguration = makeHarnessSharedRealmConfiguration(rootURL: realmRootURL)
            Realm.Configuration.defaultConfiguration = readerRealmConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration = readerRealmConfiguration
            ReaderContentLoader.historyRealmConfiguration = readerRealmConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = sharedRealmConfiguration
            LibraryDataManager.realmConfiguration = sharedRealmConfiguration
            harnessLog("bootstrap.realm.ready reader=\(readerRealmConfiguration.fileURL?.path ?? "<none>") shared=\(sharedRealmConfiguration.fileURL?.path ?? "<none>")")
        } catch {
            latestError = "Realm bootstrap failed: \(error.localizedDescription)"
            appendEvent("bootstrap.realm.error", payload: latestError ?? "unknown error")
            harnessLog("bootstrap.realm.error \(latestError ?? "unknown error")")
        }

        EbookFileManager.configure()
        harnessLog("bootstrap.ebookFileManagerConfigured")
        do {
            // The harness only needs local EPUB import and the reader-file bridge.
            // Avoid iCloud/ubiquity initialization here because it is slow and can wedge
            // smoke-mode startup before the renderer path is even mounted.
            ReaderFileManager.shared.ubiquityContainerIdentifier = nil
            ReaderFileManager.shared.cloudDrive = nil
            let storageRootURL = harnessStorageRootURL()
            harnessLog("bootstrap.localDrive.begin root=\(storageRootURL.path)")
            ReaderFileManager.shared.localDrive = try await CloudDrive(
                storage: .localDirectory(
                    rootURL: storageRootURL
                )
            )
            harnessLog("bootstrap.localDrive.ready")
        } catch {
            latestError = "ReaderFileManager init failed: \(error.localizedDescription)"
            appendEvent("bootstrap.error", payload: latestError ?? "unknown error")
        }

        ebookURLSchemeHandler.readerFileManager = ReaderFileManager.shared
        await MainActor.run {
            isBootstrapReady = true
            appendEvent("bootstrap.ready", payload: "file manager and scheme handlers configured")
        }
        await { @ReaderFileURLSchemeActor in
            readerFileURLSchemeHandler.readerFileManager = ReaderFileManager.shared
        }()
    }

    func maybeAutoImportFromCommandLine() async {
        guard !autoImportArgumentHandled else { return }
        autoImportArgumentHandled = true
        let candidate = cliOptions.bookURL
        harnessLog("cli.autoImport candidate=\(candidate?.path ?? "<none>") smoke=\(cliOptions.smokeTest)")
        guard let candidate else { return }
        await importBook(from: candidate)
    }

    func runSmokeTestIfNeeded() async {
        guard cliOptions.smokeTest, !didStartSmokeTest else { return }
        didStartSmokeTest = true
        appendEvent(
            "smoke.start",
            payload: "timeout=\(cliOptions.smokeTimeoutSeconds)s book=\(cliOptions.bookURL?.path ?? "<none>")"
        )
        harnessLog("smoke.begin timeout=\(cliOptions.smokeTimeoutSeconds)")

        do {
            if cliOptions.bookURL == nil {
                throw NSError(
                    domain: "EbookRendererHarnessSmoke",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Smoke mode requires an EPUB path argument."]
                )
            }

            try await waitUntil(
                description: "EPUB import",
                timeoutSeconds: cliOptions.smokeTimeoutSeconds
            ) { self.loadedBookURL != nil }
            try await waitUntil(
                description: "ebookViewerInitialized",
                timeoutSeconds: cliOptions.smokeTimeoutSeconds
            ) { self.eventCount(named: "ebookViewerInitialized") > 0 }
            try await waitUntil(
                description: "ebookViewerLoaded",
                timeoutSeconds: cliOptions.smokeTimeoutSeconds
            ) { self.eventCount(named: "ebookViewerLoaded") > 0 }
            try await waitUntil(
                description: "native page count",
                timeoutSeconds: cliOptions.smokeTimeoutSeconds
            ) { (self.activeWebViewState.paginationState?.pageCount ?? 0) > 0 }

            let nativePageCountInitial = activeWebViewState.paginationState?.pageCount
            try? await Task.sleep(nanoseconds: 350_000_000)
            let nativePageCountStable = activeWebViewState.paginationState?.pageCount
            let jsProbe = try await captureSmokeShellProbe()
            let navigationProbe = await captureSmokeNavigationProbe()
            try? await waitUntil(
                description: "updateCurrentContentPage after navigation probe",
                timeoutSeconds: 2
            ) { self.eventCount(named: "updateCurrentContentPage") > 0 }
            try? await waitUntil(
                description: "updateReadingProgress after navigation probe",
                timeoutSeconds: 2
            ) { self.eventCount(named: "updateReadingProgress") > 0 }
            try? await waitUntil(
                description: "ebookNavigationVisibility after navigation probe",
                timeoutSeconds: 2
            ) { self.eventCount(named: "ebookNavigationVisibility") > 0 }

            let iframeCount = jsProbe["iframeCount"] as? Int ?? -1
            let hasVisibleContentURL = (jsProbe["contentURL"] as? String)?.isEmpty == false
            let hasSectionLayoutController = (jsProbe["hasSectionLayoutController"] as? Bool) == true
            let gate1SameDocument = iframeCount == 0
                && hasVisibleContentURL
                && hasSectionLayoutController
            let gate2NativeReadback = gate1SameDocument
                && hasVisibleContentURL
                && (nativePageCountInitial ?? 0) > 0
                && nativePageCountInitial == nativePageCountStable
            let gate3NavigationFacade = (navigationProbe["nextAdvanced"] as? Bool) == true
                && (navigationProbe["prevReturned"] as? Bool) == true
            let gate4AppContract = eventCount(named: "ebookViewerLoaded") > 0
                && eventCount(named: "updateCurrentContentPage") > 0
                && eventCount(named: "updateReadingProgress") > 0
                && eventCount(named: "ebookNavigationVisibility") > 0

            let summary: [String: Any] = [
                "smokeTest": [
                    "bookURL": loadedBookURL?.absoluteString ?? "nil",
                    "bookDisplayName": loadedBookDisplayName ?? "nil",
                    "timeoutSeconds": cliOptions.smokeTimeoutSeconds,
                ],
                "events": [
                    "ebookViewerInitialized": eventCount(named: "ebookViewerInitialized"),
                    "ebookViewerLoaded": eventCount(named: "ebookViewerLoaded"),
                    "updateCurrentContentPage": eventCount(named: "updateCurrentContentPage"),
                    "updateReadingProgress": eventCount(named: "updateReadingProgress"),
                    "ebookNavigationVisibility": eventCount(named: "ebookNavigationVisibility"),
                ],
                "nativePagination": [
                    "initialPageCount": nativePageCountInitial as Any,
                    "stablePageCount": nativePageCountStable as Any,
                    "state": activeWebViewState.paginationState?.dictionaryRepresentation ?? [:],
                ],
                "jsProbe": jsProbe,
                "navigationProbe": navigationProbe,
                "gates": [
                    "gate1SameDocumentMount": gate1SameDocument,
                    "gate2NativePaginationReadback": gate2NativeReadback,
                    "gate3NavigationFacade": gate3NavigationFacade,
                    "gate4AppFacingContract": gate4AppContract,
                ],
                "overallSuccess": gate1SameDocument && gate2NativeReadback && gate3NavigationFacade && gate4AppContract,
            ]

            latestDump = prettyPrintedResult(summary)
            let overallSuccess = summary["overallSuccess"] as? Bool ?? false
            appendEvent(
                overallSuccess ? "smoke.pass" : "smoke.fail",
                payload: overallSuccess
                    ? "all smoke gates passed"
                    : "gates=\(prettyPrintedResult(summary["gates"]))"
            )
            harnessLog("smoke.summary: \(latestDump)")
            await terminateAfterSmoke(exitCode: overallSuccess ? 0 : 1)
        } catch {
            latestError = "Smoke test failed: \(error.localizedDescription)"
            let failureSummary: [String: Any] = [
                "smokeTest": [
                    "bookURL": loadedBookURL?.absoluteString ?? cliOptions.bookURL?.absoluteString ?? "nil",
                    "timeoutSeconds": cliOptions.smokeTimeoutSeconds,
                ],
                "error": latestError ?? error.localizedDescription,
            ]
            latestDump = prettyPrintedResult(failureSummary)
            appendEvent("smoke.fail", payload: latestError ?? error.localizedDescription)
            harnessLog("smoke.summary: \(latestDump)")
            await terminateAfterSmoke(exitCode: 1)
        }
    }

    func importBook(from url: URL) async {
        await bootstrapIfNeeded()
        do {
            let readerURL: URL?
            if cliOptions.smokeTest {
                readerURL = try await importBookForSmoke(from: url)
            } else {
                readerURL = try await ReaderFileManager.shared.importFile(fileURL: url, fromDownloadURL: nil)
            }
            guard let readerURL else {
                latestError = "Import returned no reader URL for \(url.lastPathComponent)"
                appendEvent("import.failed", payload: latestError ?? "unknown error")
                return
            }
            loadedBookURL = readerURL
            loadedBookDisplayName = url.lastPathComponent
            hasLoadedLastPosition = false
            latestError = nil
            appendEvent("import.succeeded", payload: "\(url.lastPathComponent) -> \(readerURL.absoluteString)")
            loadCurrentBook()
        } catch {
            latestError = "Import failed: \(error.localizedDescription)"
            appendEvent("import.failed", payload: latestError ?? "unknown error")
        }
    }

    private func importBookForSmoke(from url: URL) async throws -> URL? {
        guard let drive = ReaderFileManager.shared.localDrive else {
            return nil
        }

        let targetDirectory = RootRelativePath.ebooks
        let targetFilePath = targetDirectory.appending(url.lastPathComponent)
        let targetURL = try targetFilePath.fileURL(forRoot: drive.rootDirectory)

        let shouldStopAccessingFile = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessingFile {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try await drive.createDirectory(at: targetDirectory)
        if !(try await drive.fileExists(at: targetFilePath)) {
            try await drive.upload(from: url, to: targetFilePath)
        }

        appendEvent("import.smoke.bypass", payload: targetURL.path)
        guard let readerURL = try await ReaderFileManager.shared.readerFileURL(for: targetURL, drive: drive) else {
            return nil
        }

        do {
            let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                forPackageURL: readerURL,
                readerFileManager: ReaderFileManager.shared
            )
            harnessLog("import.smoke.cachedSource entries=\(cachedSource.entries.count)")
            appendEvent("import.smoke.cachedSource", payload: "entries=\(cachedSource.entries.count)")
        } catch {
            harnessLog("import.smoke.cachedSource.error \(error.localizedDescription)")
            appendEvent("import.smoke.cachedSource.error", payload: error.localizedDescription)
        }

        return readerURL
    }

    func loadCurrentBook() {
        guard let loadedBookURL else {
            latestError = "No EPUB has been imported yet."
            return
        }
        navigator.load(URLRequest(url: loadedBookURL))
        appendEvent("load.request", payload: loadedBookURL.absoluteString)
    }

    func reloadCurrentBook() {
        hasLoadedLastPosition = false
        loadCurrentBook()
    }

    func reloadCurrentPage() {
        navigator.reload()
        appendEvent("reload.page", payload: activeWebViewState.pageURL.absoluteString)
    }

    func jumpToCurrentTarget() async {
        let target = jumpTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        do {
            _ = try await scriptCaller.evaluateJavaScript(
                "globalThis.reader?.view?.goTo(target)",
                arguments: ["target": target]
            )
            appendEvent("jump.request", payload: target)
        } catch {
            latestError = "Jump failed: \(error.localizedDescription)"
            appendEvent("jump.failed", payload: latestError ?? "unknown error")
        }
    }

    func goToNextSection() async {
        await runSimpleCommand(
            "globalThis.reader?.view?.renderer?.nextSection?.()",
            eventName: "navigation.nextSection"
        )
    }

    func goToPreviousSection() async {
        await runSimpleCommand(
            "globalThis.reader?.view?.renderer?.prevSection?.()",
            eventName: "navigation.prevSection"
        )
    }

    func dumpSelectedState() async {
        do {
            switch selectedDumpKind {
            case .pagination:
                latestDump = prettyPrintedJSONObject([
                    "webViewState": paginationDictionary(),
                    "pageURL": activeWebViewState.pageURL.absoluteString,
                    "loadedBookURL": loadedBookURL?.absoluteString ?? "nil",
                    "currentContentPageURL": currentContentPageURL ?? "nil",
                    "hideNavigationDueToScroll": hideNavigationDueToScroll,
                ])
            case .renderer:
                let result = try await scriptCaller.evaluateJavaScript(
                    """
                    (async () => {
                      const renderer = globalThis.reader?.view?.renderer;
                      const [pageNumber, pageCount] = await Promise.all([
                        renderer?.page?.() ?? null,
                        renderer?.pages?.() ?? null,
                      ]);
                      return {
                        shellURL: globalThis.location?.href ?? null,
                        contentURL: globalThis.reader?.view?.document?.location?.href ?? null,
                        sectionCount: globalThis.reader?.book?.sections?.length ?? null,
                        lastLocation: globalThis.reader?.view?.lastLocation ?? null,
                        pageNumber,
                        pageCount,
                        cacheWarmerTotalPages: globalThis.cacheWarmerTotalPages ?? null,
                        cacheWarmerPageCounts: Array.from(globalThis.cacheWarmerPageCounts?.entries?.() ?? []).slice(0, 40),
                        writingDirectionSnapshot: globalThis.manabiGetWritingDirectionSnapshot?.() ?? null,
                        navHidden: document.getElementById('nav-bar')?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
                      };
                    })()
                    """
                )
                latestDump = prettyPrintedResult(result)
            }
            appendEvent("dump.\(selectedDumpKind.rawValue)", payload: "updated")
        } catch {
            latestError = "Dump failed: \(error.localizedDescription)"
            appendEvent("dump.failed", payload: latestError ?? "unknown error")
        }
    }

    func applyPresentationOverrides() async {
        do {
            _ = try await scriptCaller.evaluateJavaScript(
                """
                (() => {
                  document.body?.setAttribute?.('data-manabi-light-theme', lightTheme);
                  document.body?.setAttribute?.('data-manabi-dark-theme', darkTheme);
                  document.documentElement?.setAttribute?.('data-harness-dark-mode-setting', darkModeSetting);
                  return true;
                })()
                """,
                arguments: [
                    "lightTheme": lightModeTheme.rawValue,
                    "darkTheme": darkModeTheme.rawValue,
                    "darkModeSetting": darkModeSetting.rawValue,
                ]
            )
            _ = try await scriptCaller.evaluateJavaScript(
                "window.setEbookViewerWritingDirection(direction)",
                arguments: ["direction": writingDirection.rawValue]
            )
            appendEvent(
                "presentation.sync",
                payload: "light=\(lightModeTheme.rawValue) dark=\(darkModeTheme.rawValue) direction=\(writingDirection.rawValue)"
            )
        } catch {
            latestError = "Presentation sync failed: \(error.localizedDescription)"
            appendEvent("presentation.sync.failed", payload: latestError ?? "unknown error")
        }
    }

    func noteNavigationFinished() {
        appendEvent("webview.navigationFinished", payload: activeWebViewState.pageURL.absoluteString)
    }

    func noteNavigationCommitted() {
        appendEvent("webview.navigationCommitted", payload: activeWebViewState.pageURL.absoluteString)
    }

    func noteNavigationFailed() {
        appendEvent(
            "webview.navigationFailed",
            payload: "\(activeWebViewState.pageURL.absoluteString) :: \(activeWebViewState.error?.localizedDescription ?? "no error")"
        )
    }

    private func runSimpleCommand(_ js: String, eventName: String) async {
        do {
            _ = try await scriptCaller.evaluateJavaScript(js)
            appendEvent(eventName, payload: "ok")
        } catch {
            latestError = "\(eventName) failed: \(error.localizedDescription)"
            appendEvent("\(eventName).failed", payload: latestError ?? "unknown error")
        }
    }

    private func handleMessage(named name: String, message: WebViewMessage) async {
        switch name {
        case "ebookViewerInitialized":
            appendEvent(name, payload: messagePayloadSummary(message.body))
            guard let loadedBookURL else { return }
            do {
                _ = try await scriptCaller.evaluateJavaScript(
                    "window.loadEBook({ url, layoutMode })",
                    arguments: [
                        "url": loadedBookURL.absoluteString,
                        "layoutMode": "paginated",
                    ]
                )
                appendEvent("ebook.loadEBook", payload: loadedBookURL.absoluteString)
            } catch {
                latestError = "loadEBook failed: \(error.localizedDescription)"
                appendEvent("ebook.loadEBook.failed", payload: latestError ?? "unknown error")
            }
        case "ebookViewerLoaded":
            appendEvent(name, payload: messagePayloadSummary(message.body))
            if cliOptions.smokeTest, !isPaginationEnabled {
                isPaginationEnabled = true
                appendEvent("pagination.enabled", payload: "enabled after ebookViewerLoaded")
            }
            if !hasLoadedLastPosition {
                do {
                    _ = try await scriptCaller.evaluateJavaScript(
                        "window.loadLastPosition({ cfi, fractionalCompletion })",
                        arguments: [
                            "cfi": lastKnownCFI,
                            "fractionalCompletion": lastKnownFractionalCompletion,
                        ]
                    )
                    hasLoadedLastPosition = true
                    appendEvent(
                        "ebook.loadLastPosition",
                        payload: "cfi=\(lastKnownCFI.isEmpty ? "<empty>" : lastKnownCFI) fraction=\(lastKnownFractionalCompletion)"
                    )
                } catch {
                    latestError = "loadLastPosition failed: \(error.localizedDescription)"
                    appendEvent("ebook.loadLastPosition.failed", payload: latestError ?? "unknown error")
                }
            }
            await applyPresentationOverrides()
            await dumpSelectedState()
        case "pageMetadataUpdated":
            if let metadata = PageMetadataUpdatedMessage(fromMessage: message) {
                loadedBookDisplayName = metadata.title
                appendEvent(
                    name,
                    payload: "title=\(metadata.title) author=\(metadata.author) url=\(metadata.url?.absoluteString ?? "<nil>")"
                )
            } else {
                appendEvent(name, payload: messagePayloadSummary(message.body))
            }
        case "updateReadingProgress":
            if let progress = FractionalCompletionMessage(fromMessage: message) {
                lastKnownCFI = progress.cfi
                lastKnownFractionalCompletion = Double(progress.fractionalCompletion)
                appendEvent(
                    name,
                    payload: "fraction=\(progress.fractionalCompletion) cfi=\(progress.cfi) reason=\(progress.reason)"
                )
            } else {
                appendEvent(name, payload: messagePayloadSummary(message.body))
            }
        case "updateCurrentContentPage":
            if let body = message.body as? [String: Any],
               let currentPageURL = body["currentPageURL"] as? String {
                currentContentPageURL = currentPageURL
            }
            appendEvent(name, payload: messagePayloadSummary(message.body))
        case "ebookNavigationVisibility":
            if let body = message.body as? [String: Any],
               let nextValue = body["hideNavigationDueToScroll"] as? Bool {
                hideNavigationDueToScroll = nextValue
            }
            appendEvent(name, payload: messagePayloadSummary(message.body))
        default:
            appendEvent(name, payload: messagePayloadSummary(message.body))
        }
    }

    private func paginationDictionary() -> [String: String] {
        var values = activeWebViewState.paginationState?.dictionaryRepresentation ?? [:]
        values["selectedViewport"] = viewportPreset.title
        values["selectedViewportWidth"] = "\(Int(viewportPreset.size.width))"
        values["selectedViewportHeight"] = "\(Int(viewportPreset.size.height))"
        values["loadedBookURL"] = loadedBookURL?.absoluteString ?? "nil"
        return values
    }

    private func appendEvent(_ name: String, payload: String) {
        let record = HarnessEventRecord(name: name, payload: payload)
        events.append(record)
        if events.count > 250 {
            events.removeFirst(events.count - 250)
        }
        harnessLog("\(name): \(payload)")
    }

    private func eventCount(named name: String) -> Int {
        events.reduce(into: 0) { partialResult, record in
            if record.name == name {
                partialResult += 1
            }
        }
    }

    private func waitUntil(
        description: String,
        timeoutSeconds: Double,
        pollIntervalNanoseconds: UInt64 = 150_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw NSError(
            domain: "EbookRendererHarnessSmoke",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)."]
        )
    }

    private func captureSmokeShellProbe() async throws -> [String: Any] {
        let result = try await scriptCaller.evaluateJavaScript(
            """
            const renderer = globalThis.reader?.view?.renderer;
            const liveDocument = globalThis.reader?.view?.document ?? null;
            const rendererContentURLs = Array.from(renderer?.getContents?.() ?? [])
              .slice(0, 8)
              .map(entry => entry?.doc?.location?.href ?? null);
            const iframeSources = Array.from(document.querySelectorAll('iframe'))
              .slice(0, 8)
              .map(frame => frame?.src ?? null);
            return {
              shellURL: globalThis.location?.href ?? null,
              contentURL: liveDocument?.location?.href ?? rendererContentURLs.find(url => !!url) ?? null,
              iframeCount: iframeSources.length,
              iframeSources,
              rendererContentURLs,
              hasSectionLayoutController: !!(
                liveDocument?.defaultView?.manabiEbookSectionLayoutController
                ?? globalThis.manabiEbookSectionLayoutController
              ),
              sectionCount: globalThis.reader?.book?.sections?.length ?? null,
              currentIndex: renderer?.currentIndex ?? null,
              writingDirectionSnapshot: globalThis.manabiGetWritingDirectionSnapshot?.() ?? null,
              navigationFunctions: {
                viewNext: typeof globalThis.reader?.view?.next === 'function',
                viewPrev: typeof globalThis.reader?.view?.prev === 'function',
                viewGoRight: typeof globalThis.reader?.view?.goRight === 'function',
                viewGoLeft: typeof globalThis.reader?.view?.goLeft === 'function',
                rendererGoTo: typeof renderer?.goTo === 'function',
                rendererNextSection: typeof renderer?.nextSection === 'function',
                rendererPrevSection: typeof renderer?.prevSection === 'function',
              },
            };
            """
        )
        return decodeJSONObjectResult(result)
    }

    private func captureSmokeNavigationProbe() async -> [String: Any] {
        func movementDetected(from before: [String: Any], to after: [String: Any], previousContentPageURL: String?, currentContentPageURL: String?) -> Bool {
            let beforeIndex = before["currentIndex"] as? Int
            let afterIndex = after["currentIndex"] as? Int
            if let beforeIndex, let afterIndex, beforeIndex != afterIndex {
                return true
            }

            let beforeContentURL = before["contentURL"] as? String
            let afterContentURL = after["contentURL"] as? String
            if beforeContentURL != afterContentURL {
                return true
            }

            if previousContentPageURL != currentContentPageURL {
                return true
            }

            return false
        }

        let before = (try? await captureSmokeShellProbe()) ?? ["raw": "capture failed"]
        let beforeCurrentContentPageURL = currentContentPageURL
        let beforeUpdateCurrentContentPageCount = eventCount(named: "updateCurrentContentPage")
        let beforeUpdateReadingProgressCount = eventCount(named: "updateReadingProgress")
        let beforeNavigationVisibilityCount = eventCount(named: "ebookNavigationVisibility")

        let navigationFunctions = before["navigationFunctions"] as? [String: Any] ?? [:]
        let canNext = (navigationFunctions["viewNext"] as? Bool) == true
        let canPrev = (navigationFunctions["viewPrev"] as? Bool) == true
        let canGoRight = (navigationFunctions["viewGoRight"] as? Bool) == true
        let canGoLeft = (navigationFunctions["viewGoLeft"] as? Bool) == true

        var afterNext = before
        var afterPrev = before
        var nextAdvanced = false
        var prevReturned = false

        if canNext {
            _ = try? await scriptCaller.evaluateJavaScript(
                """
                if (globalThis.reader?.view?.next) {
                  void globalThis.reader.view.next();
                }
                return true;
                """
            )
            try? await Task.sleep(nanoseconds: 700_000_000)
            afterNext = (try? await captureSmokeShellProbe()) ?? ["raw": "capture failed"]
            nextAdvanced = movementDetected(
                from: before,
                to: afterNext,
                previousContentPageURL: beforeCurrentContentPageURL,
                currentContentPageURL: currentContentPageURL
            )
        }

        if canPrev {
            let beforePrevContentPageURL = currentContentPageURL
            _ = try? await scriptCaller.evaluateJavaScript(
                """
                if (globalThis.reader?.view?.prev) {
                  void globalThis.reader.view.prev();
                }
                return true;
                """
            )
            try? await Task.sleep(nanoseconds: 700_000_000)
            afterPrev = (try? await captureSmokeShellProbe()) ?? ["raw": "capture failed"]
            let returnedToOrigin =
                (before["currentIndex"] as? Int) == (afterPrev["currentIndex"] as? Int)
                && (before["contentURL"] as? String) == (afterPrev["contentURL"] as? String)
            let contentPageReturned = beforeCurrentContentPageURL == currentContentPageURL
            prevReturned = returnedToOrigin || contentPageReturned || !movementDetected(
                from: afterNext,
                to: afterPrev,
                previousContentPageURL: beforePrevContentPageURL,
                currentContentPageURL: currentContentPageURL
            )
        }

        if canGoRight {
            _ = try? await scriptCaller.evaluateJavaScript(
                """
                if (globalThis.reader?.view?.goRight) {
                  void globalThis.reader.view.goRight();
                }
                return true;
                """
            )
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        if canGoLeft {
            _ = try? await scriptCaller.evaluateJavaScript(
                """
                if (globalThis.reader?.view?.goLeft) {
                  void globalThis.reader.view.goLeft();
                }
                return true;
                """
            )
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        return [
            "before": before,
            "afterNext": afterNext,
            "afterPrev": afterPrev,
            "nextAttempted": canNext,
            "prevAttempted": canPrev,
            "goRightAttempted": canGoRight,
            "goLeftAttempted": canGoLeft,
            "nextAdvanced": nextAdvanced,
            "prevReturned": prevReturned,
            "updateCurrentContentPageDelta": eventCount(named: "updateCurrentContentPage") - beforeUpdateCurrentContentPageCount,
            "updateReadingProgressDelta": eventCount(named: "updateReadingProgress") - beforeUpdateReadingProgressCount,
            "ebookNavigationVisibilityDelta": eventCount(named: "ebookNavigationVisibility") - beforeNavigationVisibilityCount,
            "currentContentPageURL": currentContentPageURL ?? "nil",
        ]
    }

    private func terminateAfterSmoke(exitCode: Int32) async {
        #if os(macOS)
        try? await Task.sleep(nanoseconds: 800_000_000)
        fflush(stdout)
        fflush(stderr)
        NSApplication.shared.hide(nil)
        Darwin.exit(exitCode)
        #endif
    }

    private func messagePayloadSummary(_ body: Any) -> String {
        if let string = body as? String {
            return string
        }
        return prettyPrintedResult(body)
    }

    private func decodeJSONObjectResult(_ result: Any?) -> [String: Any] {
        if let dictionary = result as? [String: Any] {
            return dictionary
        }
        if let string = result as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return ["raw": prettyPrintedResult(result)]
    }

    private func prettyPrintedResult(_ result: Any?) -> String {
        guard let result else { return "nil" }
        if let string = result as? String {
            if let data = string.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(object),
               let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let pretty = String(data: formatted, encoding: .utf8) {
                return pretty
            }
            return string
        }
        if JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let pretty = String(data: data, encoding: .utf8) {
            return pretty
        }
        return String(describing: result)
    }

    private func prettyPrintedJSONObject(_ object: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let pretty = String(data: data, encoding: .utf8) {
            return pretty
        }
        return String(describing: object)
    }
}

private struct HarnessSidebarView: View {
    @ObservedObject var model: EbookRendererHarnessModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Book") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Import EPUB") {
                            model.isImportingBook = true
                        }
                        if let loadedBookDisplayName = model.loadedBookDisplayName {
                            Text(loadedBookDisplayName)
                                .font(.headline)
                        } else {
                            Text("No EPUB loaded")
                                .foregroundStyle(.secondary)
                        }
                        if let loadedBookURL = model.loadedBookURL {
                            Text(loadedBookURL.absoluteString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Reload Shell") {
                                model.reloadCurrentBook()
                            }
                            Button("Reload Current Page") {
                                model.reloadCurrentPage()
                            }
                        }
                        HStack {
                            Button("Previous Section") {
                                Task { await model.goToPreviousSection() }
                            }
                            Button("Next Section") {
                                Task { await model.goToNextSection() }
                            }
                        }
                    }
                }

                GroupBox("Pagination") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Runtime Pagination", isOn: $model.isPaginationEnabled)
                        Picker("Mode", selection: $model.paginationMode) {
                            Text("LTR").tag(WebViewPaginationMode.leftToRight)
                            Text("RTL").tag(WebViewPaginationMode.rightToLeft)
                            Text("TTB").tag(WebViewPaginationMode.topToBottom)
                            Text("BTT").tag(WebViewPaginationMode.bottomToTop)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Use View Length (`pageLength == 0`)", isOn: $model.usesViewLength)
                        if !model.usesViewLength {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Explicit Page Length: \(Int(model.explicitPageLength))")
                                Slider(value: $model.explicitPageLength, in: 200...1800, step: 1)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Page Gap: \(Int(model.pageGap))")
                            Slider(value: $model.pageGap, in: 0...80, step: 1)
                        }
                    }
                }

                GroupBox("Viewport") {
                    Picker("Preset", selection: $model.viewportPreset) {
                        ForEach(HarnessViewportPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                }

                GroupBox("Presentation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Color Scheme", selection: $model.darkModeSetting) {
                            Text("System").tag(DarkModeSetting.system)
                            Text("Dark").tag(DarkModeSetting.darkModeOverride)
                            Text("Light").tag(DarkModeSetting.alwaysLightMode)
                        }
                        Picker("Light Theme", selection: $model.lightModeTheme) {
                            ForEach(LightModeTheme.allCases) { theme in
                                Text(theme.rawValue.capitalized).tag(theme)
                            }
                        }
                        Picker("Dark Theme", selection: $model.darkModeTheme) {
                            ForEach(DarkModeTheme.allCases) { theme in
                                Text(theme.rawValue.capitalized).tag(theme)
                            }
                        }
                        Picker("Writing Direction", selection: $model.writingDirection) {
                            ForEach(HarnessWritingDirection.allCases) { direction in
                                Text(direction.rawValue.capitalized).tag(direction)
                            }
                        }
                        Button("Apply Presentation Overrides") {
                            Task { await model.applyPresentationOverrides() }
                        }
                    }
                }

                GroupBox("Navigation") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("CFI or href", text: $model.jumpTarget)
                            .textFieldStyle(.roundedBorder)
                        Button("Jump") {
                            Task { await model.jumpToCurrentTarget() }
                        }
                    }
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Dump", selection: $model.selectedDumpKind) {
                            ForEach(HarnessDumpKind.allCases) { kind in
                                Text(kind.rawValue.capitalized).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        Button("Dump Current State") {
                            Task { await model.dumpSelectedState() }
                        }
                        if let latestError = model.latestError {
                            Text(latestError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 320, idealWidth: 360)
    }
}

private struct HarnessWebViewPane: View {
    @ObservedObject var model: EbookRendererHarnessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.webViewState.pageURL.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                if let pageCount = model.webViewState.paginationState?.pageCount {
                    Text("pages \(pageCount)")
                        .font(.caption.monospaced())
                }
            }

            WebView(
                config: WebViewConfig(
                    contentRules: nil,
                    dataDetectorsEnabled: false,
                    isOpaque: true,
                    backgroundColor: .clear,
                    darkModeSetting: model.darkModeSetting,
                    paginationConfiguration: model.paginationConfiguration
                ),
                navigator: model.navigator,
                state: Binding(
                    get: { model.webViewState },
                    set: { model.webViewState = $0 }
                ),
                scriptCaller: model.scriptCaller,
                obscuredInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                bounces: true,
                schemeHandlers: [
                    (model.readerFileURLSchemeHandler, "reader-file"),
                    (model.ebookURLSchemeHandler, "ebook"),
                ],
                onNavigationCommitted: { _ in
                    model.noteNavigationCommitted()
                },
                onNavigationFinished: { _ in
                    model.noteNavigationFinished()
                },
                onNavigationFailed: { _ in
                    model.noteNavigationFailed()
                },
                hideNavigationDueToScroll: Binding(
                    get: { model.hideNavigationDueToScroll },
                    set: { model.hideNavigationDueToScroll = $0 }
                ),
                textSelection: Binding(
                    get: { model.textSelection },
                    set: { model.textSelection = $0 }
                )
            )
            .environment(\.webViewMessageHandlers, model.messageHandlers)
            .frame(
                width: model.viewportPreset.size.width,
                height: model.viewportPreset.size.height
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .animation(.easeInOut(duration: 0.2), value: model.viewportPreset)

            TabView {
                ScrollView {
                    Text(model.latestDump.isEmpty ? "No dump yet." : model.latestDump)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .tabItem { Text("Dump") }

                List(model.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.name)
                            .font(.caption.bold())
                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(event.payload)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .tabItem { Text("Events") }
            }
            .frame(minHeight: 260)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HarnessRootView: View {
    @StateObject private var model = EbookRendererHarnessModel()

    var body: some View {
        HSplitView {
            HarnessSidebarView(model: model)
            HarnessWebViewPane(model: model)
        }
        .onAppear {
            harnessLog("rootView.onAppear")
        }
        .task {
            harnessLog("rootView.task.begin")
            await model.bootstrapIfNeeded()
            await model.maybeAutoImportFromCommandLine()
            await model.runSmokeTestIfNeeded()
        }
        .fileImporter(
            isPresented: $model.isImportingBook,
            allowedContentTypes: [.epub, .epubZip],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importBook(from: url) }
        }
    }
}

private struct HarnessSmokeRootView: View {
    @StateObject private var model = EbookRendererHarnessModel()

    var body: some View {
        Group {
            if model.isBootstrapReady {
                WebView(
                    config: WebViewConfig(
                        contentRules: nil,
                        dataDetectorsEnabled: false,
                        isOpaque: true,
                        backgroundColor: .clear,
                        darkModeSetting: model.darkModeSetting,
                        paginationConfiguration: model.paginationConfiguration
                    ),
                    navigator: model.navigator,
                    state: Binding(
                        get: { model.currentWebViewStateForSmokeBinding() },
                        set: { model.updateWebViewStateForSmokeBinding($0) }
                    ),
                    scriptCaller: model.scriptCaller,
                    obscuredInsets: EdgeInsets(),
                    bounces: true,
                    schemeHandlers: [
                        (model.readerFileURLSchemeHandler, "reader-file"),
                        (model.ebookURLSchemeHandler, "ebook"),
                    ],
                    onNavigationCommitted: { _ in
                        model.noteNavigationCommitted()
                    },
                    onNavigationFinished: { _ in
                        model.noteNavigationFinished()
                    },
                    onNavigationFailed: { _ in
                        model.noteNavigationFailed()
                    },
                    hideNavigationDueToScroll: Binding(
                        get: { model.hideNavigationDueToScroll },
                        set: { model.hideNavigationDueToScroll = $0 }
                    ),
                    textSelection: Binding(
                        get: { model.textSelection },
                        set: { model.textSelection = $0 }
                    )
                )
            } else {
                Color.clear
            }
        }
        .environment(\.webViewMessageHandlers, model.messageHandlers)
        .frame(width: model.viewportPreset.size.width, height: model.viewportPreset.size.height)
        .onAppear {
            harnessLog("smokeRoot.onAppear")
        }
        .task {
            harnessLog("smokeRoot.task.begin")
            await model.bootstrapIfNeeded()
            await model.maybeAutoImportFromCommandLine()
            await model.runSmokeTestIfNeeded()
        }
    }
}

#if os(macOS)
private final class HarnessSmokeAppDelegate: NSObject, NSApplicationDelegate {
    private var smokeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HarnessCLIOptions.current.smokeTest else { return }

        let rootView = HarnessSmokeRootView()
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1680, height: 1180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ebook Renderer Harness"
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        smokeWindow = window

        harnessLog("appDelegate.didFinishLaunching.smokeWindow")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif

@main
private struct EbookRendererHarnessApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(HarnessSmokeAppDelegate.self) private var appDelegate
#endif

    init() {
        harnessLog("app.init")
#if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
#endif
    }

    var body: some Scene {
        WindowGroup("Ebook Renderer Harness") {
            if HarnessCLIOptions.current.smokeTest {
                EmptyView()
            } else {
                HarnessRootView()
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1680, height: 1180)
    }
}
