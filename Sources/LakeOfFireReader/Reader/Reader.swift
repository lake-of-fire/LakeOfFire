import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
#if os(iOS)
import UIKit
#endif

fileprivate func lakeReaderLoadDebugLog(_ message: String) {
    let line = "# LOAD \(message)\n"
    print(line, terminator: "")
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/manabi-reader-load.log")
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

private func logBook(_ message: @autoclosure () -> String) {
    _ = message
}

#if os(iOS)
private func currentWindowTopSafeAreaInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }?
        .safeAreaInsets.top ?? 0
}
#endif

private func readerLoadDurationString(_ interval: TimeInterval) -> String {
    let milliseconds = Int64((max(0, Double(interval)) * 1_000).rounded())
    let seconds = milliseconds / 1_000
    let rawFractionalString = String(milliseconds % 1_000)
    let fractionalString = String(repeating: "0", count: max(0, 3 - rawFractionalString.count)) + rawFractionalString
    return "\(seconds).\(fractionalString)s"
}

private struct ReaderStatusBarFadeOverlay: ViewModifier {
    var topFadeHeight: CGFloat
    var backgroundColor: Color

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if topFadeHeight > 0 {
                LinearGradient(
                    stops: [
                        .init(color: backgroundColor, location: 0),
                        .init(color: backgroundColor.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: topFadeHeight)
                .ignoresSafeArea(.all, edges: .top)
                .allowsHitTesting(false)
            }
        }
    }
}

private func readerThemeBackgroundColor(
    colorScheme: ColorScheme,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme
) -> Color {
    switch colorScheme {
    case .dark:
        switch darkModeTheme {
        case .black:
            return .black
        case .gray:
            return Color(red: Double(0x31) / 255, green: Double(0x32) / 255, blue: Double(0x34) / 255)
        }
    default:
        switch lightModeTheme {
        case .white:
            return .white
        case .beige:
            return Color(red: Double(0xf7) / 255, green: Double(0xf0) / 255, blue: Double(0xd8) / 255)
        }
    }
}

private extension View {
    func readerStatusBarFade(top: CGFloat, backgroundColor: Color) -> some View {
        modifier(ReaderStatusBarFadeOverlay(topFadeHeight: top, backgroundColor: backgroundColor))
    }

#if os(iOS)
    @ViewBuilder
    func readerStatusBarFadeForCurrentDevice(top: CGFloat, backgroundColor: Color) -> some View {
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .phone {
            readerStatusBarFade(top: top, backgroundColor: backgroundColor)
        } else {
            self
        }
    }

#endif
}

private func logSafeArea(_ message: @autoclosure () -> String) {
    _ = message()
}

private func logMay8(_ message: @autoclosure () -> String) {
}

private func logEPUBBack(_ message: @autoclosure () -> String) {
}

typealias ReaderSettingsJavaScriptEvaluator = (_ js: String, _ duplicateInMultiTargetFrames: Bool) async throws -> Void

private var ebookChromeInsetRevision: Int = 0

@MainActor
func readerPaginationTrackingSettingsKey(
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme
) -> String {
    "pagination-size:v1|font:\(readerFontSize ?? 0)|light:\(lightModeTheme.rawValue)|dark:\(darkModeTheme.rawValue)"
}

@MainActor
func applyAdaptiveReaderWidth(
    readerFontSize: Double?,
    reason: String,
    requestGeometryBake: Bool,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard hasAsyncCaller else {
#if DEBUG
#endif
        return
    }
    let maxWidthOverride = readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: readerFontSize)
    do {
        try await evaluateJavaScript(
            "document.body?.style?.setProperty('--mnb-reader-max-width-override', '\(maxWidthOverride)');",
            true
        )
        if requestGeometryBake {
            await requestReaderTrackingSectionGeometryBake(reason: reason, evaluateJavaScript: evaluateJavaScript)
        }
    } catch {
        print("Adaptive reader width update failed: \(error)")
    }
}

@MainActor
func syncReaderPaginationTrackingSettingsKey(
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    reason: String,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard hasAsyncCaller else {
#if DEBUG
#endif
        return
    }
    let key = readerPaginationTrackingSettingsKey(
        readerFontSize: readerFontSize,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme
    )
    do {
        try await evaluateJavaScript(
            "window.paginationTrackingSettingsKey = '" + key + "';",
            true
        )
#if DEBUG
#endif
    } catch {
#if DEBUG
#endif
    }
}

@MainActor
func requestReaderTrackingSectionGeometryBake(
    reason: String,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    do {
        try await evaluateJavaScript(
            "window.reader?.view?.renderer?.requestTrackingSectionGeometryBake?.({ reason: '\(reason)', restoreLocation: true, immediate: true });",
            true
        )
    } catch {
        print("Geometry bake request failed: \(error)")
    }
}

@MainActor
func requestReaderTypographyPaginationRefresh(
    reason: String,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    do {
        try await evaluateJavaScript(
            """
            (async function() {
                const renderer = globalThis.reader?.view?.renderer;
                if (renderer?.renderIfTypographyChanged) {
                    return await renderer.renderIfTypographyChanged('\(reason)');
                }
                return { rendered: false, reason: 'missing-renderer' };
            })();
            """,
            true
        )
    } catch {
        print("Typography pagination refresh failed: \(error)")
    }
}

@MainActor
func applyReaderFontSize(
    _ size: Double,
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    reason: String,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard hasAsyncCaller else {
#if DEBUG
#endif
        return
    }
    do {
        try await evaluateJavaScript(
            """
            (function() {
                const fontSize = '\(size)px';
                const applyFontSize = (doc) => {
                    const body = doc?.body;
                    if (!body) { return false; }
                    body.style.fontSize;
                    body.style.fontSize = fontSize;
                    return true;
                };
                globalThis.manabiReaderFontSizeCSS = fontSize;
                globalThis.manabiApplyReaderFontSizeToEbookDocuments = (reason = 'manual', explicitDoc = null) => {
                    let appliedCount = 0;
                    const docs = [];
                    if (explicitDoc) { docs.push(explicitDoc); }
                    try {
                        const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
                        for (const content of contents) {
                            const doc = content?.doc ?? content?.document ?? null;
                            if (doc && !docs.includes(doc)) { docs.push(doc); }
                        }
                    } catch (_) {}
                    for (const doc of docs) {
                        if (applyFontSize(doc)) { appliedCount += 1; }
                    }
                    return { reason, appliedCount, fontSize };
                };
                let appliedCount = applyFontSize(document) ? 1 : 0;
                try {
                    appliedCount += globalThis.manabiApplyReaderFontSizeToEbookDocuments?.('lake-reader-font-size')?.appliedCount ?? 0;
                } catch (_) {}
                return { appliedCount, fontSize };
            })();
            """,
            true
        )
        await syncReaderPaginationTrackingSettingsKey(
            readerFontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: "font-size-change",
            hasAsyncCaller: hasAsyncCaller,
            evaluateJavaScript: evaluateJavaScript
        )
        await requestReaderTypographyPaginationRefresh(reason: reason, evaluateJavaScript: evaluateJavaScript)
        await requestReaderTrackingSectionGeometryBake(reason: reason, evaluateJavaScript: evaluateJavaScript)
    } catch {
        print("Font size update failed: \(error)")
    }
}

@MainActor
func applyReaderTheme(
    colorScheme: ColorScheme,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    reason: String,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard hasAsyncCaller else { return }
    let colorSchemeValue = colorScheme == .dark ? "dark" : "light"
    do {
        try await evaluateJavaScript(
            """
            (function() {
                const colorScheme = '\(colorSchemeValue)';
                const lightModeTheme = '\(lightModeTheme.rawValue)';
                const darkModeTheme = '\(darkModeTheme.rawValue)';
                const applyTheme = (doc) => {
                    const body = doc?.body;
                    if (!body) { return false; }
                    body.dataset.mnbColorScheme = colorScheme;
                    body.dataset.mnbLightTheme = lightModeTheme;
                    body.dataset.mnbDarkTheme = darkModeTheme;
                    doc.documentElement?.style?.setProperty?.('color-scheme', colorScheme);
                    body.style?.setProperty?.('color-scheme', colorScheme);
                    return true;
                };
                globalThis.manabiReaderColorScheme = colorScheme;
                globalThis.manabiReaderLightModeTheme = lightModeTheme;
                globalThis.manabiReaderDarkModeTheme = darkModeTheme;
                globalThis.manabiApplyReaderThemeToEbookDocuments = (reason = 'manual', explicitDoc = null) => {
                    let appliedCount = 0;
                    const docs = [];
                    if (explicitDoc) { docs.push(explicitDoc); }
                    try {
                        const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
                        for (const content of contents) {
                            const doc = content?.doc ?? content?.document ?? null;
                            if (doc && !docs.includes(doc)) { docs.push(doc); }
                        }
                    } catch (_) {}
                    for (const doc of docs) {
                        if (applyTheme(doc)) { appliedCount += 1; }
                    }
                    return { reason, appliedCount, colorScheme, lightModeTheme, darkModeTheme };
                };
                let appliedCount = applyTheme(document) ? 1 : 0;
                appliedCount += globalThis.manabiApplyReaderThemeToEbookDocuments('\(reason)')?.appliedCount ?? 0;
                return { appliedCount, colorScheme, lightModeTheme, darkModeTheme };
            })();
            """,
            true
        )
    } catch {
        print("Reader theme update failed: \(error)")
    }
}

@MainActor
func applyInitialReaderPresentationSettings(
    readerFontSize: Double?,
    colorScheme: ColorScheme,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    await syncReaderPaginationTrackingSettingsKey(
        readerFontSize: readerFontSize,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme,
        reason: "initial",
        hasAsyncCaller: hasAsyncCaller,
        evaluateJavaScript: evaluateJavaScript
    )
    await applyAdaptiveReaderWidth(
        readerFontSize: readerFontSize,
        reason: "reader-width-initial",
        requestGeometryBake: readerFontSize == nil,
        hasAsyncCaller: hasAsyncCaller,
        evaluateJavaScript: evaluateJavaScript
    )
    await applyReaderTheme(
        colorScheme: colorScheme,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme,
        reason: "initial",
        hasAsyncCaller: hasAsyncCaller,
        evaluateJavaScript: evaluateJavaScript
    )
    if let readerFontSize {
        await applyReaderFontSize(
            readerFontSize,
            readerFontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: "font-size-initial",
            hasAsyncCaller: hasAsyncCaller,
            evaluateJavaScript: evaluateJavaScript
        )
    }
}

@MainActor
private func ebookToolbarBottomOffset(
    obscuredBottomInset: CGFloat,
    additionalBottomSafeAreaInset: CGFloat
) -> CGFloat {
    let obscuredBottomInset = max(0, obscuredBottomInset)
    let additionalBottomSafeAreaInset = max(0, additionalBottomSafeAreaInset)
    guard additionalBottomSafeAreaInset > 0 else { return obscuredBottomInset }
    // Keep the EPUB toolbar above the minimized-detent clearance, but bias it slightly downward
    // so the centered chapter-progress label is not needlessly floating above the sheet.
    let fullClearanceOffset = max(obscuredBottomInset, additionalBottomSafeAreaInset)
    return max(0, fullClearanceOffset - 4)
}

@MainActor
func syncEbookViewerChromeInsets(
    pageURL: URL,
    obscuredTopInset: CGFloat,
    toolbarBottomOffset: CGFloat,
    obscuredBottomInset: CGFloat,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard pageURL.isEBookURL else { return }
    guard hasAsyncCaller else { return }
    ebookChromeInsetRevision += 1
    let revision = ebookChromeInsetRevision
    let obscuredTopInset = max(0, obscuredTopInset)
    let toolbarBottomOffset = max(0, toolbarBottomOffset)
    let obscuredBottomInset = max(0, obscuredBottomInset)
    let obscuredTopInsetCSS = "\(obscuredTopInset)px"
    let toolbarBottomOffsetCSS = "\(toolbarBottomOffset)px"
    let obscuredBottomInsetCSS = "\(obscuredBottomInset)px"
    logMay8("native.lakeReader.syncChromeInsets.begin pageURL=\(pageURL.absoluteString) revision=\(revision) obscuredTopInset=\(obscuredTopInset) toolbarBottomOffset=\(toolbarBottomOffset) obscuredBottomInset=\(obscuredBottomInset)")
    do {
        try await evaluateJavaScript(
            """
            (function() {
              const postMay8 = (_stage, _payload = {}) => {};
              const hasApplyFunction = typeof window.manabiApplyChromeInsets === 'function';
              const obscuredTopInset = '\(obscuredTopInsetCSS)';
              const toolbarBottomOffset = '\(toolbarBottomOffsetCSS)';
              const obscuredBottomInset = '\(obscuredBottomInsetCSS)';
              postMay8('before', {
                hasApplyFunction,
                previousInsets: window.__manabiChromeInsets || null,
                obscuredTopInset,
                toolbarBottomOffset,
                obscuredBottomInset,
                revision: \(revision),
              });
              const appliedInsets = {
                obscuredTopInset,
                toolbarBottomOffset,
                obscuredBottomInset,
                source: 'native',
                revision: \(revision),
              };
              window.__manabiChromeInsets = appliedInsets;
              if (hasApplyFunction) {
                window.manabiApplyChromeInsets(appliedInsets, 'native-sync');
                postMay8('after.applyFunction', { appliedInsets });
                return;
              }
              const targets = [document.documentElement, document.body].filter(Boolean);
              for (const target of targets) {
                target.style.setProperty('--mnb-toolbar-bottom-offset', toolbarBottomOffset);
              }
              postMay8('after.fallbackStyle', { appliedInsets });
            })();
            """,
            true
        )
        logMay8("native.lakeReader.syncChromeInsets.end pageURL=\(pageURL.absoluteString) revision=\(revision) obscuredTopInset=\(obscuredTopInset) toolbarBottomOffset=\(toolbarBottomOffset) obscuredBottomInset=\(obscuredBottomInset)")
    } catch {
        logMay8("native.lakeReader.syncChromeInsets.error pageURL=\(pageURL.absoluteString) revision=\(revision) error=\(error.localizedDescription)")
        logEPUBBack("stage=lakeReader.syncChromeInsets.error pageURL=\(pageURL.absoluteString) revision=\(revision) error=\(error.localizedDescription)")
    }
}

fileprivate struct ThemeModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var defaultFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body) + 4
    @AppStorage("readerFontSize") internal var readerFontSize: Double?
    @AppStorage("lightModeTheme") var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") var darkModeTheme: DarkModeTheme = .black
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var scriptCaller: WebViewScriptCaller
    @EnvironmentObject var readerViewModel: ReaderViewModel

    private var resolvedReaderFontSize: Double {
        readerFontSize ?? Double(defaultFontSize)
    }

    private var initialReaderPresentationSettingsTaskID: String {
        [
            readerViewModel.state.pageURL.absoluteString,
            String(readerViewModel.state.hasReaderRenderReady),
            String(scriptCaller.hasAsyncCaller),
            String(resolvedReaderFontSize),
            colorScheme == .dark ? "dark" : "light",
            lightModeTheme.rawValue,
            darkModeTheme.rawValue,
        ].joined(separator: "|")
    }

    private func applyFontSize(_ size: Double, reason: String) async {
        await applyReaderFontSize(
            size,
            readerFontSize: size,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: reason,
            hasAsyncCaller: scriptCaller.hasAsyncCaller
        ) { js, duplicateInMultiTargetFrames in
            _ = try await scriptCaller.evaluateJavaScript(
                js,
                duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
            )
        }
    }

    @MainActor
    private func applyTheme(reason: String) async {
        await applyReaderTheme(
            colorScheme: colorScheme,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: reason,
            hasAsyncCaller: scriptCaller.hasAsyncCaller
        ) { js, duplicateInMultiTargetFrames in
            _ = try await scriptCaller.evaluateJavaScript(
                js,
                duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
            )
        }
    }

    @MainActor
    private func applyThemeAfterSceneActivation() async {
        for delay in [UInt64(0), 120_000_000, 450_000_000] {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard scenePhase == .active else { return }
            await applyTheme(reason: "scene-active")
        }
    }
    
    func body(content: Content) -> some View {
        content
            .onChange(of: lightModeTheme) { newValue in
                Task { @MainActor in
                    await applyReaderTheme(
                        colorScheme: colorScheme,
                        lightModeTheme: newValue,
                        darkModeTheme: darkModeTheme,
                        reason: "light-theme-change",
                        hasAsyncCaller: scriptCaller.hasAsyncCaller
                    ) { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                    await requestReaderTrackingSectionGeometryBake(reason: "light-theme-change") { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                }
            }
            .onChange(of: darkModeTheme) { newValue in
                Task { @MainActor in
                    await applyReaderTheme(
                        colorScheme: colorScheme,
                        lightModeTheme: lightModeTheme,
                        darkModeTheme: newValue,
                        reason: "dark-theme-change",
                        hasAsyncCaller: scriptCaller.hasAsyncCaller
                    ) { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                    await requestReaderTrackingSectionGeometryBake(reason: "dark-theme-change") { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                }
            }
            .onChange(of: colorScheme) { newValue in
                Task { @MainActor in
                    await applyReaderTheme(
                        colorScheme: newValue,
                        lightModeTheme: lightModeTheme,
                        darkModeTheme: darkModeTheme,
                        reason: "color-scheme-change",
                        hasAsyncCaller: scriptCaller.hasAsyncCaller
                    ) { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                }
            }
            .onChange(of: scenePhase) { scenePhase in
                guard scenePhase == .active else { return }
                Task { @MainActor in
                    await applyThemeAfterSceneActivation()
                }
            }
            .task(id: initialReaderPresentationSettingsTaskID) { @MainActor in
                await applyInitialReaderPresentationSettings(
                    readerFontSize: resolvedReaderFontSize,
                    colorScheme: colorScheme,
                    lightModeTheme: lightModeTheme,
                    darkModeTheme: darkModeTheme,
                    hasAsyncCaller: scriptCaller.hasAsyncCaller
                ) { js, duplicateInMultiTargetFrames in
                    _ = try await scriptCaller.evaluateJavaScript(
                        js,
                        duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                    )
                }
            }
            .onChange(of: readerFontSize) { newValue in
                let newValue = newValue ?? resolvedReaderFontSize
                Task { @MainActor in
                    await applyAdaptiveReaderWidth(
                        readerFontSize: newValue,
                        reason: "reader-width-change",
                        requestGeometryBake: false,
                        hasAsyncCaller: scriptCaller.hasAsyncCaller
                    ) { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                    await applyFontSize(newValue, reason: "font-size-change")
                }
            }
    }
}

fileprivate struct PageMetadataModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .onChange(of: readerViewModel.state.pageImageURL) { pageImageURL in
                guard !readerContent.isReaderProvisionallyNavigating else { return }
                guard let imageURL = pageImageURL,
                      let contentItem = readerContent.content,
                      contentItem.realm != nil else { return }
                let contentURL = contentItem.url
                guard contentURL == readerViewModel.state.pageURL else { return }
                Task { @RealmBackgroundActor in
                    let contents = try await ReaderContentLoader.loadAll(url: contentURL)
                    for content in contents where content.imageUrl == nil {
                        try await content.realm?.asyncWrite {
                            content.imageUrl = imageURL
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }
            }
            .onChange(of: readerViewModel.state.pageTitle) { pageTitle in
                Task { @MainActor in
                    try await readerViewModel.pageMetadataUpdated(title: pageTitle)
                }
            }
    }
}

fileprivate struct ReaderStateChangeModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .onChange(of: readerViewModel.state) { [oldState = readerViewModel.state] state in
                if readerContent.isReaderProvisionallyNavigating != state.isProvisionallyNavigating {
                    readerContent.isReaderProvisionallyNavigating = state.isProvisionallyNavigating
                }
                
                //            if !state.isLoading && !state.isProvisionallyNavigating, oldState.pageURL != state.pageURL, readerContent.content.url != state.pageURL {
                // May be from replaceState or pushState
                // TODO: Improve replaceState support
                //                onNavigationCommitted(state: state)
                //            }
            }
    }
}

fileprivate struct ReaderMediaPlayerViewModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    @EnvironmentObject var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject var readerViewModel: ReaderViewModel
    @EnvironmentObject var scriptCaller: WebViewScriptCaller
    
    func body(content: Content) -> some View {
        content
            .task(id: readerHeaderMediaSyncID) {
                await syncReaderHeaderMediaButton(reason: "task")
            }
            .onChange(of: readerMediaPlayerViewModel.audioURLs) { audioURLs in
                Task { @MainActor in
                    guard readerMediaPlayerViewModel.playbackSource == .recordedAudio else { return }
                    if audioURLs.isEmpty {
                        readerMediaPlayerViewModel.isMediaPlayerPresented = false
                    }
                    await syncReaderHeaderMediaButton(reason: "audioURLs")
                }
            }
            .onChange(of: readerMediaPlayerViewModel.isPlaying) { _ in
                Task { @MainActor in
                    await syncReaderHeaderMediaButton(reason: "isPlaying")
                }
            }
            .onChange(of: readerMediaPlayerViewModel.playbackSource) { _ in
                Task { @MainActor in
                    await syncReaderHeaderMediaButton(reason: "playbackSource")
                }
            }
            .onChange(of: readerModeViewModel.lastRenderedURL?.absoluteString ?? "nil") { _ in
                Task { @MainActor in
                    await syncReaderHeaderMediaButton(reason: "readerModeRendered")
                }
            }
            .onChange(of: readerViewModel.state.pageURL.absoluteString) { _ in
                Task { @MainActor in
                    await syncReaderHeaderMediaButton(reason: "webViewPageURL")
                }
            }
            .onChange(of: readerViewModel.state.hasReaderRenderReady) { _ in
                Task { @MainActor in
                    await syncReaderHeaderMediaButton(reason: "renderReady")
                }
            }
    }

    private var readerHeaderMediaSyncID: String {
        [
            readerContent.pageURL.absoluteString,
            readerContent.content?.compoundKey ?? "nil",
            String(readerContent.content?.hasAudio ?? false),
            String(readerMediaPlayerViewModel.hasRecordedAudio),
            String(readerMediaPlayerViewModel.hasPreparedAITTS),
            String(readerMediaPlayerViewModel.isPlaying),
            readerMediaPlayerViewModel.playbackSource.rawValue,
            readerModeViewModel.lastRenderedURL?.absoluteString ?? "nil",
            readerViewModel.state.pageURL.absoluteString,
            String(readerViewModel.state.hasReaderRenderReady),
        ].joined(separator: "|")
    }

    @MainActor
    private func syncReaderHeaderMediaButton(reason: String) async {
        guard scriptCaller.hasAsyncCaller else {
            return
        }
        let isPlaying = readerMediaPlayerViewModel.isPlaying
        let webViewPageURL = readerViewModel.state.pageURL
        let contentURL = readerContent.content?.url ?? readerContent.pageURL
        let contentCanonicalURL = contentURL.canonicalReaderContentURLForHotfix()
        let renderedCanonicalURL = readerModeViewModel.lastRenderedURL?.canonicalReaderContentURLForHotfix()
        let isReaderModeContent = (readerContent.content?.isReaderModeByDefault ?? false)
            || readerModeViewModel.isReaderMode
            || readerModeViewModel.pendingReaderModeURL != nil
            || renderedCanonicalURL == contentCanonicalURL
        let hasRecordedAudio = readerMediaPlayerViewModel.hasRecordedAudio || (readerContent.content?.hasAudio ?? false)
        let ttsAvailable = isReaderModeContent
            && !hasRecordedAudio
            && (readerContent.content?.hasHTML ?? false)
        let usesTTS = readerMediaPlayerViewModel.playbackSource == .aiTextToSpeech || (!hasRecordedAudio && ttsAvailable)
        let mediaAvailable = hasRecordedAudio
            || readerMediaPlayerViewModel.hasPreparedAITTS
            || ttsAvailable
        if isReaderModeContent {
            guard !webViewPageURL.isReaderURLLoaderURL else {
                return
            }
            guard renderedCanonicalURL == contentCanonicalURL || readerViewModel.state.hasReaderRenderReady else {
                return
            }
        }
        do {
            try await scriptCaller.evaluateJavaScript(
                """
                window.manabiSyncReaderHeaderMediaButton?.({
                    mediaAvailable: \(mediaAvailable ? "true" : "false"),
                    isPlaying: \(isPlaying ? "true" : "false"),
                    usesTTS: \(usesTTS ? "true" : "false"),
                    reason: '\(reason)'
                });
                """,
                duplicateInMultiTargetFrames: true
            )
        } catch {
        }
    }
}

fileprivate struct ReaderLoadingOverlayModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        let currentCanonicalURL = readerContent.pageURL.canonicalReaderContentURLForHotfix()
        let renderedCanonicalURL = readerModeViewModel.lastRenderedURL?.canonicalReaderContentURLForHotfix()
        let webViewPageURL = readerViewModel.state.pageURL
        let webViewShowingNonLoaderPage = !webViewPageURL.isNativeReaderView && !webViewPageURL.isReaderURLLoaderURL
        let expectsReaderModeCompletion = (readerContent.content?.isReaderModeByDefault ?? false)
            || readerModeViewModel.pendingReaderModeURL != nil
            || readerModeViewModel.expectedSyntheticReaderLoaderURL != nil
            || readerModeViewModel.isReaderModeLoading
            || readerContent.isRenderingReaderHTML
        let webViewHasReaderRenderReady = readerViewModel.state.hasReaderRenderReady
        let hasRenderedCurrentPage = renderedCanonicalURL == currentCanonicalURL
            && renderedCanonicalURL != nil
            && webViewShowingNonLoaderPage
        let hasVisibleContent =
            hasRenderedCurrentPage
            || (
                webViewShowingNonLoaderPage
                && expectsReaderModeCompletion
                && webViewHasReaderRenderReady
            )
            || (
                readerContent.content != nil
                && webViewShowingNonLoaderPage
                && !readerContent.isReaderProvisionallyNavigating
                && !readerContent.isRenderingReaderHTML
            )
        let shouldShowOverlay = readerModeViewModel.isReaderModeLoading && !hasVisibleContent
        content
            .modifier(
                ReaderLoadingProgressOverlayViewModifier(
                    isLoading: shouldShowOverlay,
                    context: "ReaderOverlay"
                )
            )
//            .overlay { Text(readerModeViewModel.isReaderModeLoading ? "read" : "") }
//            .overlay {
//                Text(readerModeViewModel.isReaderModeLoading.description)
//                    .font(.title)
//            }
    }
}

public struct WebViewNavigatorEnvironmentKey: EnvironmentKey {
    public static var defaultValue = WebViewNavigator()
}

public extension EnvironmentValues {
    // the new key path to access your object (\.object)
    var webViewNavigator: WebViewNavigator {
        get { self[WebViewNavigatorEnvironmentKey.self] }
        set { self[WebViewNavigatorEnvironmentKey.self] = newValue }
    }
}

public extension WebViewNavigator {
    /// Injects browser history (unlike loadHTMLWithBaseURL)
    @MainActor
    func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = ReaderFileManager.shared,
        readerModeViewModel: ReaderModeViewModel?
    ) async throws {
        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        lakeReaderLoadDebugLog("navigator.content.begin contentURL=\(content.url.absoluteString) attached=\(hasAttachedWebView) ready=\(isReadyForDirectLoad)")
        if let url = try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager) {
            lakeReaderLoadDebugLog("navigator.content.resolved contentURL=\(content.url.absoluteString) targetURL=\(url.absoluteString) attached=\(hasAttachedWebView) ready=\(isReadyForDirectLoad)")
            let loadSnapshot = debugLoadSnapshot
            let resolvedAt = CFAbsoluteTimeGetCurrent()
            if let readerModeViewModel {
                if url.isHTTP || url.isFileURL || url.isSnippetURL || url.isReaderURLLoaderURL {
                    let isLoading = content.isReaderModeByDefault || url.isReaderURLLoaderURL
                    readerModeViewModel.readerModeLoading(isLoading)
//                    debugPrint("# WebViewNavigator load", isLoading)
                }
            }
            if loadSnapshot.lastRequestURL == url.absoluteString
                || loadSnapshot.lastDataLoadBaseURL == url.absoluteString
                || loadSnapshot.lastHTMLBaseURL == url.absoluteString
                || loadSnapshot.currentWebViewURL == url.absoluteString {
                if loadSnapshot.isLoading {
                    lakeReaderLoadDebugLog("navigator.content.skipAlreadyLoading targetURL=\(url.absoluteString)")
                    return
                }
            }
            lakeReaderLoadDebugLog("navigator.content.dispatch targetURL=\(url.absoluteString)")
            load(URLRequest(url: url))
        } else {
            lakeReaderLoadDebugLog("navigator.content.nilTarget contentURL=\(content.url.absoluteString)")
        }
    }
}

public struct Reader: View {
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
//    var obscuredInsets: EdgeInsets? = nil
    var bounces = true
    var additionalTopSafeAreaInset: CGFloat? = nil
    var additionalLeadingSafeAreaInset: CGFloat? = nil
    var additionalBottomSafeAreaInset: CGFloat? = nil
    var ebookChromeBottomSafeAreaInset: CGFloat? = nil
    var ignoresSampledTopObscuredInset = false
    var hidesTopScrollEdgeEffect = false
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    @State private var obscuredInsets: EdgeInsets? = nil
    @State private var obscuredGeometrySize: CGSize? = nil
    
    public init(
        persistentWebViewID: String? = nil,
        forceReaderModeWhenAvailable: Bool = false,
//        obscuredInsets: EdgeInsets? = nil,
        bounces: Bool = true,
        additionalTopSafeAreaInset: CGFloat? = nil,
        additionalLeadingSafeAreaInset: CGFloat? = nil,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        ebookChromeBottomSafeAreaInset: CGFloat? = nil,
        ignoresSampledTopObscuredInset: Bool = false,
        hidesTopScrollEdgeEffect: Bool = false,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        hideNavigationDueToScroll: Binding<Bool> = .constant(false),
        textSelection: Binding<String?>? = nil,
        buildMenu: BuildMenuType? = nil
    ) {
        self.persistentWebViewID = persistentWebViewID
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
//        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        self.additionalTopSafeAreaInset = additionalTopSafeAreaInset
        self.additionalLeadingSafeAreaInset = additionalLeadingSafeAreaInset
        self.additionalBottomSafeAreaInset = additionalBottomSafeAreaInset
        self.ebookChromeBottomSafeAreaInset = ebookChromeBottomSafeAreaInset
        self.ignoresSampledTopObscuredInset = ignoresSampledTopObscuredInset
        self.hidesTopScrollEdgeEffect = hidesTopScrollEdgeEffect
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
        self.buildMenu = buildMenu
    }
    
    public var body: some View {
        let pageURL = readerContent.content?.url ?? readerContent.pageURL
        let statusBarFadeBackgroundColor = readerThemeBackgroundColor(
            colorScheme: colorScheme,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme
        )
        let sampledTopInset = max(0, obscuredInsets?.top ?? 0)
        let effectiveSampledTopInset: CGFloat = {
            guard ignoresSampledTopObscuredInset else { return sampledTopInset }
#if os(iOS)
            let fallbackTopInset = max(0, currentWindowTopSafeAreaInset())
            let clampedSampledInset = sampledTopInset > 0 ? min(sampledTopInset, 88) : 0
            return max(fallbackTopInset, clampedSampledInset)
#else
            return 0
#endif
        }()
        let effectiveObscuredInsets = ignoresSampledTopObscuredInset
            ? EdgeInsets(
                top: effectiveSampledTopInset,
                leading: obscuredInsets?.leading ?? 0,
                bottom: obscuredInsets?.bottom ?? 0,
                trailing: obscuredInsets?.trailing ?? 0
            )
            : obscuredInsets
        let explicitTopInset = max(0, additionalTopSafeAreaInset ?? 0)
        let effectiveTopInset = explicitTopInset
        let additionalLeadingInset = max(0, additionalLeadingSafeAreaInset ?? 0)
        let sampledBottomInset = max(0, obscuredInsets?.bottom ?? 0)
        let additionalBottomInset = max(0, additionalBottomSafeAreaInset ?? 0)
        let ebookChromeBottomInset = max(
            sampledBottomInset,
            additionalBottomInset,
            max(0, ebookChromeBottomSafeAreaInset ?? 0)
        )
        let ebookChromeExtraBottomInset = max(0, ebookChromeBottomInset - sampledBottomInset)
        let effectiveBottomInset = pageURL.isEBookURL
            ? ebookChromeBottomInset
            : max(sampledBottomInset, additionalBottomInset)
        let toolbarReferenceBottomInset = pageURL.isEBookURL
            ? ebookChromeBottomInset
            : effectiveBottomInset
        let effectiveToolbarBottomOffset = ebookToolbarBottomOffset(
            obscuredBottomInset: toolbarReferenceBottomInset,
            additionalBottomSafeAreaInset: additionalBottomInset
        )
        let viewerLoadedProbeSummary = readerViewModel.ebookViewerLoadedProbeSummary ?? "nil"
        let chromeInsetsTaskID = [
            pageURL.absoluteString,
            "\(effectiveTopInset)",
            "\(additionalLeadingInset)",
            "\(effectiveBottomInset)",
            "\(effectiveToolbarBottomOffset)",
            "\(scriptCaller.hasAsyncCaller)",
            "\(readerViewModel.state.hasReaderRenderReady)",
            "\(readerViewModel.ebookChromeInsetsResyncID)",
        ].joined(separator: "|")
        let safeAreaBottomSignature = [
            "stage=lakeReader.computeBottom",
            "pageURL=\(pageURL.absoluteString)",
            "readerContentPageURL=\(readerContent.pageURL.absoluteString)",
            "sampledBottom=\(sampledBottomInset)",
            "sampledTop=\(sampledTopInset)",
            "sampledLeading=\(obscuredInsets?.leading ?? 0)",
            "sampledTrailing=\(obscuredInsets?.trailing ?? 0)",
            "additionalTop=\(effectiveTopInset)",
            "additionalLeading=\(additionalLeadingInset)",
            "additionalBottom=\(additionalBottomInset)",
            "ebookChromeBottom=\(ebookChromeBottomInset)",
            "ebookChromeExtraBottom=\(ebookChromeExtraBottomInset)",
            "effectiveTop=\(effectiveObscuredInsets?.top ?? 0)",
            "effectiveLeading=\(effectiveObscuredInsets?.leading ?? 0)",
            "effectiveTrailing=\(effectiveObscuredInsets?.trailing ?? 0)",
            "effectiveBottom=\(effectiveBottomInset)",
            "toolbarReferenceBottom=\(toolbarReferenceBottomInset)",
            "toolbarBottomOffset=\(effectiveToolbarBottomOffset)",
            "isEBook=\(pageURL.isEBookURL)"
        ].joined(separator: " ")
        //            VStack(spacing: 0) {
        ReaderWebView(
            persistentWebViewID: persistentWebViewID,
            obscuredInsets: effectiveObscuredInsets,
            usesEBookChromeInsets: pageURL.isEBookURL,
            bounces: bounces,
            additionalTopSafeAreaInset: effectiveTopInset,
            additionalLeadingSafeAreaInset: additionalLeadingInset,
            additionalBottomSafeAreaInset: additionalBottomSafeAreaInset,
            hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
            schemeHandlers: schemeHandlers,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onURLChanged: onURLChanged,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            buildMenu: buildMenu
        )
#if os(iOS)
        .readerStatusBarFadeForCurrentDevice(
            top: effectiveSampledTopInset,//    + 8 + 2)
            backgroundColor: statusBarFadeBackgroundColor
        )
        .ignoresSafeArea(.all, edges: .all)
#endif
        .background {
            GeometryReader { geometry in
                let geometrySize = geometry.size
                let geometrySafeAreaInsets = geometry.safeAreaInsets
                Color.clear
                    .onAppear {
                        var sampledInsets = EdgeInsets(
                            top: max(0, geometrySafeAreaInsets.top),
                            leading: max(0, geometrySafeAreaInsets.leading),
                            bottom: max(0, geometrySafeAreaInsets.bottom),
                            trailing: max(0, geometrySafeAreaInsets.trailing)
                        )
                        if !pageURL.isEBookURL,
                           explicitTopInset > 0,
                           sampledInsets.top > explicitTopInset {
                            sampledInsets.top = explicitTopInset
                        }
                        logSafeArea(
                            "stage=lakeReader.geometryInitialBottom pageURL=\(pageURL.absoluteString) sampledBottom=\(sampledInsets.bottom) previousSampledBottom=\(obscuredInsets?.bottom ?? 0) additionalBottom=\(additionalBottomInset)"
                        )
                        if pageURL.isEBookURL {
                            logEPUBBack(
                                "stage=lakeReader.geometryInitial pageURL=\(pageURL.absoluteString) sampledTop=\(sampledInsets.top) sampledBottom=\(sampledInsets.bottom) previousTop=\(obscuredInsets?.top ?? 0) previousBottom=\(obscuredInsets?.bottom ?? 0) additionalTop=\(additionalTopSafeAreaInset ?? 0) additionalBottom=\(additionalBottomInset)"
                            )
                        }
                        obscuredGeometrySize = geometrySize
                        obscuredInsets = sampledInsets
                    }
                    .onChange(of: geometry.safeAreaInsets) { safeAreaInsets in
                        var sampledInsets = EdgeInsets(
                            top: max(0, safeAreaInsets.top),
                            leading: max(0, safeAreaInsets.leading),
                            bottom: max(0, safeAreaInsets.bottom),
                            trailing: max(0, safeAreaInsets.trailing)
                        )
                        let previousInsets = obscuredInsets
                        if !pageURL.isEBookURL,
                           explicitTopInset > 0,
                           sampledInsets.top > explicitTopInset {
                            sampledInsets.top = explicitTopInset
                        }
                        if !pageURL.isEBookURL,
                           let previousInsets,
                           previousInsets.top > 0,
                           sampledInsets.top > previousInsets.top {
                            sampledInsets.top = previousInsets.top
                        }
                        logSafeArea(
                            "stage=lakeReader.geometryChangedBottom pageURL=\(pageURL.absoluteString) sampledBottom=\(sampledInsets.bottom) previousSampledBottom=\(obscuredInsets?.bottom ?? 0) additionalBottom=\(additionalBottomInset)"
                        )
                        if pageURL.isEBookURL {
                            logEPUBBack(
                                "stage=lakeReader.geometryChanged pageURL=\(pageURL.absoluteString) sampledTop=\(sampledInsets.top) sampledBottom=\(sampledInsets.bottom) previousTop=\(obscuredInsets?.top ?? 0) previousBottom=\(obscuredInsets?.bottom ?? 0) additionalTop=\(additionalTopSafeAreaInset ?? 0) additionalBottom=\(additionalBottomInset)"
                            )
                        }
                        obscuredGeometrySize = geometrySize
                        obscuredInsets = sampledInsets
                    }
            }
        }
        //            }
        //#if os(iOS)
        //            .edgesIgnoringSafeArea([.top, .bottom])
        //            .ignoresSafeArea(.all, edges: [.top, .bottom])
        //#endif
//                .ignoresSafeArea(.all, edges: [.top, .bottom])
        .modifier(ReaderLoadingOverlayModifier())
        .modifier(ReaderMessageHandlersViewModifier(
            forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
            hideNavigationDueToScroll: $hideNavigationDueToScroll
        ))
        .modifier(ReaderStateChangeModifier())
        .modifier(ThemeModifier())
        .modifier(PageMetadataModifier())
        .modifier(ReaderMediaPlayerViewModifier())
        .task(id: safeAreaBottomSignature) {
            logSafeArea(safeAreaBottomSignature)
            debugPrint("# BOTTOM \(safeAreaBottomSignature)")
            logMay8("native.lakeReader.computeInsets \(safeAreaBottomSignature) sampledTop=\(sampledTopInset) explicitTop=\(explicitTopInset) effectiveTop=\(effectiveTopInset) toolbarBottomOffset=\(effectiveToolbarBottomOffset) viewerLoadedProbe=\(viewerLoadedProbeSummary) resyncID=\(readerViewModel.ebookChromeInsetsResyncID)")
            if pageURL.isEBookURL {
                logBook("lakeReader.computeInsets \(safeAreaBottomSignature) viewerLoadedProbe=\(viewerLoadedProbeSummary) resyncID=\(readerViewModel.ebookChromeInsetsResyncID)")
                logEPUBBack("stage=lakeReader.computeInsets \(safeAreaBottomSignature) sampledTop=\(sampledTopInset) explicitTop=\(explicitTopInset) effectiveTop=\(effectiveTopInset) toolbarBottomOffset=\(effectiveToolbarBottomOffset) viewerLoadedProbe=\(viewerLoadedProbeSummary) resyncID=\(readerViewModel.ebookChromeInsetsResyncID)")
            }
        }
        .task(id: chromeInsetsTaskID) {
            guard pageURL.isEBookURL else { return }
            logBook("lakeReader.chromeInsetsTask.begin pageURL=\(pageURL.absoluteString) readerContentPageURL=\(readerContent.pageURL.absoluteString) sampledTop=\(sampledTopInset) explicitTop=\(explicitTopInset) effectiveTop=\(effectiveTopInset) effectiveBottom=\(effectiveBottomInset) toolbarBottomOffset=\(effectiveToolbarBottomOffset) hasAsyncCaller=\(scriptCaller.hasAsyncCaller) readerRenderReady=\(readerViewModel.state.hasReaderRenderReady)")
            logMay8("native.lakeReader.chromeInsetsTask.begin pageURL=\(pageURL.absoluteString) readerContentPageURL=\(readerContent.pageURL.absoluteString) chromeInsetsTaskID=\(chromeInsetsTaskID) sampledTopInset=\(sampledTopInset) explicitTopInset=\(explicitTopInset) effectiveTopInset=\(effectiveTopInset) effectiveBottomInset=\(effectiveBottomInset) effectiveToolbarBottomOffset=\(effectiveToolbarBottomOffset) viewerLoadedProbeSummary=\(viewerLoadedProbeSummary) hasAsyncCaller=\(scriptCaller.hasAsyncCaller)")
            logEPUBBack("stage=lakeReader.chromeInsetsTask.begin pageURL=\(pageURL.absoluteString) sampledTopInset=\(sampledTopInset) effectiveTopInset=\(effectiveTopInset) effectiveBottomInset=\(effectiveBottomInset) effectiveToolbarBottomOffset=\(effectiveToolbarBottomOffset) viewerLoadedProbeSummary=\(viewerLoadedProbeSummary) hasAsyncCaller=\(scriptCaller.hasAsyncCaller)")
            let retryDelaysInNanoseconds: [UInt64] = [
                0,
                80_000_000,
                250_000_000,
                600_000_000,
            ]
            for (attempt, delay) in retryDelaysInNanoseconds.enumerated() {
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                logMay8("native.lakeReader.chromeInsetsTask.attempt pageURL=\(pageURL.absoluteString) attempt=\(attempt) delayNs=\(delay) hasAsyncCaller=\(scriptCaller.hasAsyncCaller) effectiveTopInset=\(effectiveTopInset) effectiveBottomInset=\(effectiveBottomInset) effectiveToolbarBottomOffset=\(effectiveToolbarBottomOffset)")
                await syncEbookViewerChromeInsets(
                    pageURL: pageURL,
                    obscuredTopInset: effectiveTopInset,
                    toolbarBottomOffset: effectiveToolbarBottomOffset,
                    obscuredBottomInset: effectiveBottomInset,
                    hasAsyncCaller: scriptCaller.hasAsyncCaller
                ) { js, duplicateInMultiTargetFrames in
                    _ = try await scriptCaller.evaluateJavaScript(
                        js,
                        duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                    )
                }
            }
        }
        .onReceive(readerContent.contentTitleSubject.receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                guard scriptCaller.hasAsyncCaller else { return }
                let rawTitle = readerContent.contentTitle
                let needsClipboardIndicator = readerContent.content?.needsClipboardIndicator ?? false
                let displayTitle = ReaderContentLoader.resolvedDisplayTitle(
                    rawTitle,
                    needsClipboardIndicator: needsClipboardIndicator
                )
                let hideRedundantSnippetTitle =
                    readerContent.content?.url.isSnippetURL == true &&
                    readerContent.snippetTitleIsGeneratedFromPrefix
                debugPrint(
                    "# SNIPPETTITLE liveSync",
                    "url=\(readerContent.content?.url.absoluteString ?? readerContent.pageURL.absoluteString)",
                    "rawTitle=\(rawTitle)",
                    "displayTitle=\(displayTitle)",
                    "hideReaderTitle=\(hideRedundantSnippetTitle)"
                )
                do {
                    try await scriptCaller.evaluateJavaScript(
                        """
                        (function() {
                          const postSnippetTitleLog = (payload) => {
                            try {
                              const message = '# SNIPPETTITLE ' + JSON.stringify(payload);
                              const webkitPrint = window.webkit?.messageHandlers?.print;
                              if (webkitPrint && typeof webkitPrint.postMessage === 'function') {
                                webkitPrint.postMessage(message);
                                return;
                              }
                              if (typeof print !== 'undefined' && print && typeof print.postMessage === 'function') {
                                print.postMessage(message);
                              }
                            } catch (_) {}
                          };
                          const el = document.getElementById('reader-title');
                          const body = document.body;
                          if (el && el.textContent !== title) {
                            el.textContent = title;
                          }
                          if (body) {
                            body.classList.toggle(bodyClassName, !!hideReaderTitle);
                          }
                          postSnippetTitleLog({
                            source: 'liveSync.js',
                            hideReaderTitle: !!hideReaderTitle,
                            bodyClassName,
                            bodyClasses: body ? body.className : null,
                            hasTitleElement: !!el,
                            titleText: el ? el.textContent : null,
                            computedDisplay: el ? window.getComputedStyle(el).display : null,
                          });
                        })();
                        """,
                        arguments: [
                            "title": displayTitle,
                            "bodyClassName": ReaderContentLoader.snippetReaderTitleSuppressionBodyClass,
                            "hideReaderTitle": hideRedundantSnippetTitle,
                        ],
                        duplicateInMultiTargetFrames: true
                    )
                } catch {
#if DEBUG
#endif
                }
            }
        }
    }
}
