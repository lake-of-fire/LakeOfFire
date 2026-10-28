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
import Perception
#if os(iOS)
import UIKit
#endif


#if os(iOS)
private func currentWindowTopSafeAreaInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }?
        .safeAreaInsets.top ?? 0
}
#endif

private enum EBookViewportStabilityCoordinator {
    static let suspiciousTopSafeAreaChangeThreshold: CGFloat = 32

    static func acceptedSampledTopInset(
        current: CGFloat,
        previous: CGFloat?,
        preservesPreviousWhenDecreasing: Bool = false
    ) -> CGFloat {
        let clampedCurrent = min(max(0, current), 88)
        guard let previous, previous > 0 else { return clampedCurrent }
        if clampedCurrent <= 0 {
            return previous
        }
        if preservesPreviousWhenDecreasing,
           clampedCurrent < previous {
            return previous
        }
        if abs(clampedCurrent - previous) > suspiciousTopSafeAreaChangeThreshold {
            return previous
        }
        return clampedCurrent
    }
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

    @ViewBuilder
    func readerWebViewSafeAreaExpansionForCurrentDevice() -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            ignoresSafeArea(.all, edges: .all)
        } else if #available(iOS 26, *) {
            // Keep the WebView inside its iPad split-view column while letting
            // its themed background continue beneath vertical reader chrome.
            // The sampled WebKit obscured insets still keep document content
            // below the native controls.
            ignoresSafeArea(.container, edges: .vertical)
        } else {
            self
        }
    }
#elseif os(macOS)
    @ViewBuilder
    func readerWebViewSafeAreaExpansionForCurrentDevice() -> some View {
        if #available(macOS 26, *) {
            ignoresSafeArea(.all, edges: .top)
        } else {
            self
        }
    }
#endif
}




typealias ReaderSettingsJavaScriptEvaluator = (_ js: String, _ duplicateInMultiTargetFrames: Bool) async throws -> Void


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
        return
    }
    let maxWidthOverride = readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: readerFontSize)
    do {
        try await evaluateJavaScript(
            """
            (() => {
                const mark = (event, payload = '') => {
                    const label = `MANABI swiftSettings.adaptiveWidth.${event}${payload ? ' ' + payload : ''}`;
                    try { performance.mark(label); } catch (_) {}
                    try { console.timeStamp?.(label); } catch (_) {}
                };
                mark('start', 'reason=\(reason) maxWidth=\(maxWidthOverride)');
                const value = '\(maxWidthOverride)';
                const style = document.body?.style;
                let changed = false;
                if (style && style.getPropertyValue('--mnb-reader-max-width-override') !== value) {
                    style.setProperty('--mnb-reader-max-width-override', value);
                    changed = true;
                }
                mark('finish', `reason=\(reason) maxWidth=\(maxWidthOverride) changed=${changed}`);
            })();
            //# sourceURL=lake-reader-adaptive-width-sync.js

            """,
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
    } catch {
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
            //# sourceURL=lake-reader-typography-refresh.js

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
        return
    }
    do {
        try await evaluateJavaScript(
            """
            (function() {
                const mark = (event, payload = '') => {
                    const label = `MANABI swiftSettings.fontSize.${event}${payload ? ' ' + payload : ''}`;
                    try { performance.mark(label); } catch (_) {}
                    try { console.timeStamp?.(label); } catch (_) {}
                };
                mark('start', 'reason=\(reason) size=\(size)');
                const fontSize = '\(size)px';
                const applyFontSize = (doc) => {
                    const body = doc?.body;
                    if (!body) { return false; }
                    if (body.style.fontSize === fontSize) { return false; }
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
                mark('finish', `reason=\(reason) size=\(size) appliedCount=${appliedCount}`);
                return { appliedCount, fontSize };
            })();
            //# sourceURL=lake-reader-font-size-sync.js

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
                    let changed = false;
                    if (body.dataset.mnbColorScheme !== colorScheme) {
                        body.dataset.mnbColorScheme = colorScheme;
                        changed = true;
                    }
                    if (body.dataset.mnbLightTheme !== lightModeTheme) {
                        body.dataset.mnbLightTheme = lightModeTheme;
                        changed = true;
                    }
                    if (body.dataset.mnbDarkTheme !== darkModeTheme) {
                        body.dataset.mnbDarkTheme = darkModeTheme;
                        changed = true;
                    }
                    if (doc.documentElement?.style?.getPropertyValue?.('color-scheme') !== colorScheme) {
                        doc.documentElement?.style?.setProperty?.('color-scheme', colorScheme);
                        changed = true;
                    }
                    if (body.style?.getPropertyValue?.('color-scheme') !== colorScheme) {
                        body.style?.setProperty?.('color-scheme', colorScheme);
                        changed = true;
                    }
                    return changed;
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
            //# sourceURL=lake-reader-theme-sync.js

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
@discardableResult
func syncEbookViewerChromeInsets(
    key: ReaderEBookChromeInsetSynchronization.Key,
    synchronization: ReaderEBookChromeInsetSynchronization,
    isCurrent: @escaping ReaderEBookChromeInsetSynchronization.Check,
    evaluateJavaScript: @MainActor (_ script: String, _ continueWhile: @escaping ReaderEBookChromeInsetSynchronization.Check) async throws -> Void
) async -> Bool {
    guard key.pageURL.isEBookURL else { return false }
    let obscuredTopInset = key.top
    let toolbarBottomOffset = key.toolbarBottom
    let obscuredBottomInset = key.bottom
    let obscuredTopInsetCSS = "\(obscuredTopInset)px"
    let toolbarBottomOffsetCSS = "\(toolbarBottomOffset)px"
    let obscuredBottomInsetCSS = "\(obscuredBottomInset)px"
    return await synchronization.deliver(key: key, isCurrent: isCurrent) { revision, current in
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
                previousInsets: window.__swiftUIWebViewObscuredInsets || null,
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
              window.__swiftUIWebViewObscuredInsets = appliedInsets;
              if (hasApplyFunction) {
                window.manabiApplyChromeInsets(appliedInsets, 'native-sync');
                postMay8('after.applyFunction', { appliedInsets });
                return;
              }
              const targets = [document.documentElement, document.body].filter(Boolean);
              for (const target of targets) {
                target.style.setProperty('--mnb-reader-stage-top-inset', obscuredTopInset);
                target.style.setProperty('--mnb-toolbar-bottom-offset', toolbarBottomOffset);
              }
              const readerStage = document.getElementById('reader-stage');
              if (readerStage) {
                readerStage.style.top = obscuredTopInset;
                readerStage.style.bottom = 'var(--mnb-reader-stage-bottom-inset, 0px)';
              }
              postMay8('after.fallbackStyle', { appliedInsets });
            })();
            //# sourceURL=lake-reader-chrome-insets-sync.js

            """,
            current
        )
    }
}

fileprivate struct ThemeModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var defaultFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body) + 4
    let readerFontSize: Double?
    let lightModeTheme: LightModeTheme
    let darkModeTheme: DarkModeTheme
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

    private var isCurrentPageEBook: Bool {
        readerViewModel.state.pageURL.scheme == "ebook"
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
                    await applyTheme(reason: "scene-active")
                }
            }
            .task(id: initialReaderPresentationSettingsTaskID) { @MainActor in
                guard !isCurrentPageEBook else { return }
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
                        try await content.realm?.asyncWritePreservingOwnership {
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

fileprivate struct ReaderHeaderMediaSyncID: Equatable {
    let readerPageURL: URL
    let contentCompoundKey: String?
    let contentHasAudio: Bool
    let hasRecordedAudio: Bool
    let hasPreparedAITTS: Bool
    let isPlaying: Bool
    let playbackSource: String
    let lastRenderedURL: URL?
    let webViewPageURL: URL
    let hasReaderRenderReady: Bool
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
            .onChange(of: readerModeViewModel.lastRenderedURL) { _ in
                Task { @MainActor in
                    await syncReaderHeaderMediaButton(reason: "readerModeRendered")
                }
            }
            .onChange(of: readerViewModel.state.pageURL) { _ in
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

    private var readerHeaderMediaSyncID: ReaderHeaderMediaSyncID {
        ReaderHeaderMediaSyncID(
            readerPageURL: readerContent.pageURL,
            contentCompoundKey: readerContent.content?.compoundKey,
            contentHasAudio: readerContent.content?.hasAudio ?? false,
            hasRecordedAudio: readerMediaPlayerViewModel.hasRecordedAudio,
            hasPreparedAITTS: readerMediaPlayerViewModel.hasPreparedAITTS,
            isPlaying: readerMediaPlayerViewModel.isPlaying,
            playbackSource: readerMediaPlayerViewModel.playbackSource.rawValue,
            lastRenderedURL: readerModeViewModel.lastRenderedURL,
            webViewPageURL: readerViewModel.state.pageURL,
            hasReaderRenderReady: readerViewModel.state.hasReaderRenderReady
        )
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
        let availability = ReaderAudioAvailabilitySnapshot(
            contentURL: readerContent.content?.url,
            pageURL: webViewPageURL,
            isReaderModeContent: isReaderModeContent,
            recordedAudioURLs: readerContent.content?.resolvedVoiceAudioURLs ?? [],
            hasLoadedRecordedMedia: readerMediaPlayerViewModel.hasRecordedAudio
        )
        let hasRecordedAudio = availability.hasRecordedAudio
        let ttsAvailable = availability.canReadAloud
        let usesTTS = readerMediaPlayerViewModel.playbackSource == .aiTextToSpeech || (!hasRecordedAudio && ttsAvailable)
        let mediaAvailable = availability.hasAnyPlayableAudio
            || readerMediaPlayerViewModel.hasPreparedAITTS
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
    let isEnabled: Bool

    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            if isEnabled {
                let currentCanonicalURL = readerContent.pageURL
                    .canonicalReaderContentURLForHotfix()
                let renderedCanonicalURL = readerModeViewModel.lastRenderedURL?
                    .canonicalReaderContentURLForHotfix()
                let webViewPageURL = readerViewModel.state.pageURL
                let webViewShowingNonLoaderPage =
                    !webViewPageURL.isNativeReaderView
                    && !webViewPageURL.isReaderURLLoaderURL
                let expectsReaderModeCompletion =
                    (readerContent.content?.isReaderModeByDefault ?? false)
                    || readerModeViewModel.pendingReaderModeURL != nil
                    || readerModeViewModel.expectedSyntheticReaderLoaderURL
                        != nil
                    || readerModeViewModel.isReaderModeLoading
                    || readerContent.isRenderingReaderHTML
                let webViewHasReaderRenderReady = readerViewModel.state
                    .hasReaderRenderReady
                let hasRenderedCurrentPage =
                    renderedCanonicalURL == currentCanonicalURL
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
                let shouldShowOverlay =
                    readerModeViewModel.isReaderModeLoading
                    && !hasVisibleContent
                content.modifier(
                    ReaderLoadingProgressOverlayViewModifier(
                        isLoading: shouldShowOverlay
                    )
                )
            } else {
                content
            }
        }
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

    var readerReservedTopChromeInset: CGFloat {
        get { self[ReaderReservedTopChromeInsetEnvironmentKey.self] }
        set { self[ReaderReservedTopChromeInsetEnvironmentKey.self] = newValue }
    }
}

public struct ReaderReservedTopChromeInsetEnvironmentKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 0
}

enum ReaderContentSelectionOpenAction: Equatable {
    case recordHistoryVisit
    case navigate

    static func resolve(
        contentURL: URL,
        currentPageURL: URL
    ) -> ReaderContentSelectionOpenAction {
        contentURL.matchesReaderURL(currentPageURL)
            ? .recordHistoryVisit
            : .navigate
    }
}

/// Distinguishes a refusal from a request accepted by the navigator (including
/// queueing before native attachment), even if later synchronously superseded.
public enum ReaderContentLoadResult: Equatable, Sendable {
    case suppressed
    case issued(WebViewNavigator.NavigationDispatchReceipt)
}

public extension WebViewNavigator {
    @MainActor
    func openReaderContentSelection(
        _ content: any ReaderContentProtocol,
        currentPageURL: URL,
        readerModeViewModel: ReaderModeViewModel?,
        source: String = "WebViewNavigator.openReaderContentSelection"
    ) async throws {
        try Task.checkCancellation()
        // Choosing an already-mounted item is still a newer user intent and
        // must retire any earlier resolver that has not dispatched yet.
        beginNavigationIntent()
        switch ReaderContentSelectionOpenAction.resolve(
            contentURL: content.url,
            currentPageURL: currentPageURL
        ) {
        case .recordHistoryVisit:
            try await ReaderContentLoader.recordHistoryVisit(
                for: content,
                source: "\(source).alreadyLoaded"
            )
        case .navigate:
            try await load(
                content: content,
                readerModeViewModel: readerModeViewModel
            )
        }
    }

    /// Injects browser history (unlike loadHTMLWithBaseURL)
    @MainActor
    func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = ReaderFileManager.shared,
        readerModeViewModel: ReaderModeViewModel?,
        shouldLoad: @MainActor () -> Bool = { true },
        willDispatchLoad: @MainActor () -> Void = {}
    ) async throws {
        _ = try await loadResolvedContent(
            content: content, readerModeViewModel: readerModeViewModel, shouldLoad: shouldLoad,
            willDispatchLoad: willDispatchLoad,
            resolveURL: {
                try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager)
            }
        )
    }

    /// The callback runs synchronously after navigator request acceptance, with no
    /// intervening await. A caller revealing another surface must first verify
    /// the receipt is still current and its own account/source admission holds.
    /// This overload's shouldLoad is a pure permission predicate and may run
    /// again after synchronous publications. The legacy overload retains its
    /// single accepted-hint callback, which may dismiss its own presentation.
    @MainActor
    func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = ReaderFileManager.shared,
        readerModeViewModel: ReaderModeViewModel?,
        shouldLoad: @MainActor () -> Bool = { true },
        willDispatchLoad: @MainActor () -> Void = {},
        forceReload: Bool = false,
        didDispatchLoad: @MainActor (NavigationDispatchReceipt) -> Void
    ) async throws -> ReaderContentLoadResult {
        try await loadResolvedContent(
            content: content, readerModeViewModel: readerModeViewModel,
            shouldLoad: shouldLoad, willDispatchLoad: willDispatchLoad,
            forceReload: forceReload,
            revalidateAdmissionBeforeDispatch: true,
            didDispatchLoad: didDispatchLoad,
            resolveURL: {
                try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager)
            }
        )
    }

    /// Shared execution path; the resolver permits deterministic suspension tests
    /// without replacing navigation or presentation effects with a model.
    @MainActor
    internal func loadResolvedContent(
        content: any ReaderContentProtocol,
        readerModeViewModel: ReaderModeViewModel?,
        shouldLoad: @MainActor () -> Bool,
        willDispatchLoad: @MainActor () -> Void = {},
        forceReload: Bool = false,
        revalidateAdmissionBeforeDispatch: Bool = false,
        didDispatchLoad: @MainActor (NavigationDispatchReceipt) -> Void = { _ in },
        resolveURL: @MainActor () async throws -> URL?
    ) async throws -> ReaderContentLoadResult {
        try Task.checkCancellation()
        // Reserve before resolving, so a newer unresolved same-URL selection
        // supersedes this intent without relying on changes to a URL tuple.
        let intent = beginNavigationIntent()
        let beginSnapshot = debugLoadSnapshot
        let resolvedURL: URL?
        do {
            resolvedURL = try await resolveURL()
        } catch {
            // A typed caller must not present a retired resolver's failure as
            // a retry error for the newer navigation. Legacy errors propagate.
            if revalidateAdmissionBeforeDispatch && !isCurrent(intent) { return .suppressed }
            throw error
        }
        if let url = resolvedURL {
            try Task.checkCancellation()
            // Callers refreshing an existing document can lose ownership while
            // native content is being resolved. Check before any UI mutation.
            guard isCurrent(intent), shouldLoad(), isCurrent(intent) else { return .suppressed }
            let loadSnapshot = debugLoadSnapshot
            if loadSnapshot.lastRequestURL == url.absoluteString
                || loadSnapshot.lastDataLoadBaseURL == url.absoluteString
                || loadSnapshot.lastHTMLBaseURL == url.absoluteString
                || loadSnapshot.currentWebViewURL == url.absoluteString {
                if loadSnapshot.isLoading && !forceReload {
                    return .suppressed
                }
            }
            let navigatorMovedSinceBegin =
                beginSnapshot.currentWebViewURL != loadSnapshot.currentWebViewURL
                || beginSnapshot.lastRequestURL != loadSnapshot.lastRequestURL
                || beginSnapshot.lastDataLoadBaseURL != loadSnapshot.lastDataLoadBaseURL
                || beginSnapshot.lastHTMLBaseURL != loadSnapshot.lastHTMLBaseURL
            let targetStillCurrent =
                loadSnapshot.currentWebViewURL == url.absoluteString
                || loadSnapshot.lastRequestURL == url.absoluteString
                || loadSnapshot.lastDataLoadBaseURL == url.absoluteString
                || loadSnapshot.lastHTMLBaseURL == url.absoluteString
            if navigatorMovedSinceBegin && !targetStillCurrent {
                return .suppressed
            }
            // No presentation effect may precede the stale-navigation check.
            if let readerModeViewModel,
               url.isHTTP || url.isFileURL || url.isSnippetURL || url.isReaderURLLoaderURL {
                readerModeViewModel.readerModeLoading(content.isReaderModeByDefault || url.isReaderURLLoaderURL)
            }
            // Legacy shouldLoad callbacks can issue an accepted navigation hint
            // that deliberately removes their own source presentation. Invoke
            // that effectful callback exactly once. The typed API opts into a
            // pure permission check again at each synchronous publication seam.
            guard isCurrent(intent) else { return .suppressed }
            if revalidateAdmissionBeforeDispatch {
                try Task.checkCancellation()
                guard shouldLoad(), isCurrent(intent) else { return .suppressed }
            }
            willDispatchLoad()
            guard isCurrent(intent) else { return .suppressed }
            if revalidateAdmissionBeforeDispatch {
                try Task.checkCancellation()
                guard shouldLoad(), isCurrent(intent) else { return .suppressed }
            }
            switch dispatch(URLRequest(url: url), for: intent) {
            case .refused:
                return .suppressed
            case .issued(let receipt):
                didDispatchLoad(receipt)
                return .issued(receipt)
            }
        } else {
            return .suppressed
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
    var showsLoadingOverlay = true
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onDocumentContextInvalidated: (@MainActor (WebViewState, WebViewDocumentContextInvalidationReason) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    let onScrollBottomStateChanged: (@MainActor (Bool) -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readerReservedTopChromeInset) private var reservedTopChromeInset
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    
    @StateObject private var ebookChromeInsetSynchronization = ReaderEBookChromeInsetSynchronization()
    @StateObject private var titleSynchronization = ReaderTitleSynchronization()
    @State private var titleProjectionEventRevision: UInt64 = 0
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
        showsLoadingOverlay: Bool = true,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onDocumentContextInvalidated: (@MainActor (WebViewState, WebViewDocumentContextInvalidationReason) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        onScrollBottomStateChanged: (@MainActor (Bool) -> Void)? = nil,
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
        self.showsLoadingOverlay = showsLoadingOverlay
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onDocumentContextInvalidated = onDocumentContextInvalidated
        self.onURLChanged = onURLChanged
        self.onScrollBottomStateChanged = onScrollBottomStateChanged
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
        let rawSampledBottomInset = max(0, obscuredInsets?.bottom ?? 0)
        let sampledBottomInset = pageURL.isEBookURL ? 0 : rawSampledBottomInset
        let effectiveObscuredInsets: EdgeInsets? = {
            if ignoresSampledTopObscuredInset {
                return EdgeInsets(
                    top: effectiveSampledTopInset,
                    leading: obscuredInsets?.leading ?? 0,
                    bottom: sampledBottomInset,
                    trailing: obscuredInsets?.trailing ?? 0
                )
            }
            guard pageURL.isEBookURL else {
                return obscuredInsets
            }
            return EdgeInsets(
                top: effectiveSampledTopInset,
                leading: obscuredInsets?.leading ?? 0,
                bottom: sampledBottomInset,
                trailing: obscuredInsets?.trailing ?? 0
            )
        }()
        let explicitTopInset = max(
            0,
            additionalTopSafeAreaInset ?? 0,
            reservedTopChromeInset
        )
        let effectiveTopInset = pageURL.isEBookURL
            ? max(explicitTopInset, effectiveSampledTopInset)
            : explicitTopInset
        let additionalLeadingInset = max(0, additionalLeadingSafeAreaInset ?? 0)
        let additionalBottomInset = pageURL.isEBookURL
            ? 0
            : max(0, additionalBottomSafeAreaInset ?? 0)
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
        let titleSnapshot = readerContent.captureTitleSnapshot()
        let titleTaskID = ReaderTitleSynchronizationTaskID(
            source: titleSnapshot?.identity, binding: scriptCaller.currentJavaScriptBindingToken,
            nativePageURL: readerContent.pageURL, renderedURL: readerViewModel.state.pageURL,
            renderReady: readerViewModel.state.hasReaderRenderReady,
            provisionallyNavigating: readerContent.isReaderProvisionallyNavigating
                || readerViewModel.state.isProvisionallyNavigating,
            eventRevision: titleProjectionEventRevision)
        let insetNativePageURL = readerContent.pageURL
        let insetBinding = scriptCaller.currentJavaScriptBindingToken
        let insetRenderedURL = readerViewModel.state.pageURL
        let insetCachedContentURL = readerContent.cachedContentURL
        let chromeInsetKey = insetBinding.map {
            ReaderEBookChromeInsetSynchronization.Key(
                pageURL: pageURL, renderedURL: insetRenderedURL,
                cachedContentURL: insetCachedContentURL, binding: $0,
                top: max(0, effectiveTopInset), toolbarBottom: max(0, effectiveToolbarBottomOffset),
                bottom: max(0, effectiveBottomInset), resyncID: readerViewModel.ebookChromeInsetsResyncID)
        }
        let chromeInsetsTaskID = ReaderEBookChromeInsetsTaskID(
            key: chromeInsetKey, nativePageURL: insetNativePageURL,
            additionalLeadingInset: additionalLeadingInset,
            hasAsyncCaller: scriptCaller.hasAsyncCaller,
            renderReady: readerViewModel.state.hasReaderRenderReady,
            provisionallyNavigating: readerViewModel.state.isProvisionallyNavigating
                || readerContent.isReaderProvisionallyNavigating)
        //            VStack(spacing: 0) {
        ReaderWebView(
            persistentWebViewID: persistentWebViewID,
            obscuredInsets: effectiveObscuredInsets,
            usesEBookChromeInsets: pageURL.isEBookURL,
            bounces: bounces,
            additionalTopSafeAreaInset: effectiveTopInset,
            additionalLeadingSafeAreaInset: additionalLeadingInset,
            additionalBottomSafeAreaInset: pageURL.isEBookURL ? 0 : additionalBottomSafeAreaInset,
            hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
            schemeHandlers: schemeHandlers,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onDocumentContextInvalidated: onDocumentContextInvalidated,
            onURLChanged: onURLChanged,
            onScrollBottomStateChanged: onScrollBottomStateChanged,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            buildMenu: buildMenu,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme
        )
#if os(iOS)
        .readerStatusBarFadeForCurrentDevice(
            top: effectiveSampledTopInset,//    + 8 + 2)
            backgroundColor: statusBarFadeBackgroundColor
        )
#endif
        .readerWebViewSafeAreaExpansionForCurrentDevice()
        .background {
            GeometryReader { geometry in
                WithPerceptionTracking {
                    let geometrySize = geometry.size
                    let geometrySafeAreaInsets = geometry.safeAreaInsets
                    let currentPageURL = pageURL
                    let currentObscuredInsets = obscuredInsets
                    let currentHideNavigationDueToScroll = hideNavigationDueToScroll
                    Color.clear
#if DEBUG
                        // WKWebView's macOS accessibility frame reports its
                        // unobscured document viewport even when SwiftUI has
                        // expanded the rendered surface beneath native chrome.
                        // Expose the post-expansion geometry so UI tests can
                        // verify the surface separately from document insets.
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("ReaderWebView.Surface")
#endif
                        .onAppear {
                            var sampledInsets = EdgeInsets(
                                top: max(0, geometrySafeAreaInsets.top),
                                leading: max(0, geometrySafeAreaInsets.leading),
                                bottom: max(0, geometrySafeAreaInsets.bottom),
                                trailing: max(0, geometrySafeAreaInsets.trailing)
                            )
                            if currentPageURL.isEBookURL {
                                sampledInsets.top = EBookViewportStabilityCoordinator.acceptedSampledTopInset(
                                    current: sampledInsets.top,
                                    previous: currentObscuredInsets?.top,
                                    preservesPreviousWhenDecreasing: currentHideNavigationDueToScroll
                                )
                            } else if explicitTopInset > 0,
                                      sampledInsets.top > explicitTopInset {
                                sampledInsets.top = explicitTopInset
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
                            if currentPageURL.isEBookURL {
                                sampledInsets.top = EBookViewportStabilityCoordinator.acceptedSampledTopInset(
                                    current: sampledInsets.top,
                                    previous: previousInsets?.top,
                                    preservesPreviousWhenDecreasing: currentHideNavigationDueToScroll
                                )
                            } else {
                                if explicitTopInset > 0,
                                   sampledInsets.top > explicitTopInset {
                                    sampledInsets.top = explicitTopInset
                                }
                                if let previousInsets,
                                   previousInsets.top > 0,
                                   sampledInsets.top > previousInsets.top {
                                    sampledInsets.top = previousInsets.top
                                }
                            }
                            obscuredGeometrySize = geometrySize
                            obscuredInsets = sampledInsets
                        }
                }
            }
        }
        //            }
        //#if os(iOS)
        //            .edgesIgnoringSafeArea([.top, .bottom])
        //            .ignoresSafeArea(.all, edges: [.top, .bottom])
        //#endif
//                .ignoresSafeArea(.all, edges: [.top, .bottom])
        .modifier(ReaderLoadingOverlayModifier(
            isEnabled: showsLoadingOverlay
        ))
        .modifier(ReaderMessageHandlersViewModifier(
            forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
            hideNavigationDueToScroll: $hideNavigationDueToScroll
        ))
        .modifier(ReaderStateChangeModifier())
        .modifier(ThemeModifier(
            readerFontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme
        ))
        .modifier(PageMetadataModifier())
        .modifier(ReaderMediaPlayerViewModifier())
        .task(id: chromeInsetsTaskID) { @MainActor in
            guard !Task.isCancelled else { return }
            guard let key = chromeInsetsTaskID.key, key.pageURL.isEBookURL,
                  chromeInsetsTaskID.hasAsyncCaller, !chromeInsetsTaskID.provisionallyNavigating else {
                ebookChromeInsetSynchronization.retire()
                return
            }
            let caller = scriptCaller
            let content = readerContent
            let viewModel = readerViewModel
            await syncEbookViewerChromeInsets(
                key: key, synchronization: ebookChromeInsetSynchronization,
                isCurrent: {
                    caller.currentJavaScriptBindingToken == key.binding
                        && content.pageURL == chromeInsetsTaskID.nativePageURL
                        && content.cachedContentURL == key.cachedContentURL
                        && viewModel.state.pageURL == key.renderedURL
                        && !content.isReaderProvisionallyNavigating
                        && !viewModel.state.isProvisionallyNavigating
                }
            ) { js, current in
                _ = try await caller.evaluateJavaScriptInMultiTargetFrames(
                    js, propagatesFrameErrors: true, continueWhile: current)
            }
        }
        .onDisappear { ebookChromeInsetSynchronization.retire() }
        .onReceive(readerContent.titleSnapshotSubject) { _ in
            // The typed producer invalidates the value projection. Capture the
            // current source in body before scheduling, rather than reading a
            // mutable title from inside an unretained delayed task.
            titleProjectionEventRevision &+= 1
        }
        .task(id: titleTaskID) { @MainActor in
            guard !Task.isCancelled else { return }
            guard let snapshot = titleSnapshot, let binding = titleTaskID.binding,
                  titleTaskID.renderedURL.matchesReaderURL(snapshot.contentURL),
                  !titleTaskID.provisionallyNavigating else {
                titleSynchronization.retire()
                return
            }
            let caller = scriptCaller
            let content = readerContent
            let viewModel = readerViewModel
            await titleSynchronization.deliver(snapshot: snapshot, binding: binding,
                renderReady: titleTaskID.renderReady,
                isCurrent: {
                    caller.currentJavaScriptBindingToken == binding
                        && content.pageURL == titleTaskID.nativePageURL
                        && viewModel.state.pageURL == titleTaskID.renderedURL
                        && !content.isReaderProvisionallyNavigating
                        && !viewModel.state.isProvisionallyNavigating
                }
            ) { script, arguments, current in
                _ = try await caller.evaluateJavaScriptInMultiTargetFrames(
                    script, arguments: arguments, propagatesFrameErrors: true, continueWhile: current)
            }
        }
        .onDisappear { titleSynchronization.retire() }

    }
}
