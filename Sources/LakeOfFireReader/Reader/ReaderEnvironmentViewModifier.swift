import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUIWebView

struct ReaderWebViewStateKey: EnvironmentKey {
    static let defaultValue: WebViewState = .empty
}

struct ReaderCanGoBackKey: EnvironmentKey {
    static let defaultValue = false
}

struct ReaderCanGoForwardKey: EnvironmentKey {
    static let defaultValue = false
}

struct IsReaderLoadingKey: EnvironmentKey {
    static let defaultValue = false
}

struct RefreshSettingsInReaderKey: EnvironmentKey {
    static let defaultValue: @MainActor (any ReaderContentProtocol, WebViewState?) -> Void = { _, _ in }
}

struct IsReaderModeLoadPendingKey: EnvironmentKey {
    static let defaultValue: @MainActor (any ReaderContentProtocol) -> Bool = { _ in false }
}

public extension EnvironmentValues {
    var readerWebViewState: WebViewState {
        get { self[ReaderWebViewStateKey.self] }
        set { self[ReaderWebViewStateKey.self] = newValue }
    }
    var readerCanGoBack: Bool {
        get { self[ReaderCanGoBackKey.self] }
        set { self[ReaderCanGoBackKey.self] = newValue }
    }
    var readerCanGoForward: Bool {
        get { self[ReaderCanGoForwardKey.self] }
        set { self[ReaderCanGoForwardKey.self] = newValue }
    }
    var isReaderLoading: Bool {
        get { self[IsReaderLoadingKey.self] }
        set { self[IsReaderLoadingKey.self] = newValue }
    }
    var refreshSettingsInReader: @MainActor (any ReaderContentProtocol, WebViewState?) -> Void {
        get { self[RefreshSettingsInReaderKey.self] }
        set { self[RefreshSettingsInReaderKey.self] = newValue }
    }
    var isReaderModeLoadPending: @MainActor (any ReaderContentProtocol) -> Bool {
        get { self[IsReaderModeLoadPendingKey.self] }
        set { self[IsReaderModeLoadPendingKey.self] = newValue }
    }
}

fileprivate struct ReaderViewModelModifier: ViewModifier {
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .environment(\.readerWebViewState, readerViewModel.state)
            .environment(\.readerCanGoBack, readerViewModel.state.canGoBack)
            .environment(\.readerCanGoForward, readerViewModel.state.canGoForward)
            .environment(\.isReaderLoading, readerViewModel.state.isLoading)
            .environment(\.refreshSettingsInReader, readerViewModel.refreshSettingsInWebView)
            .environmentObject(readerViewModel.scriptCaller)
    }
}

fileprivate struct ReaderModeLoadPendingModifier: ViewModifier {
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    
    func body(content: Content) -> some View {
        content
            .environment(\.isReaderModeLoadPending, readerModeViewModel.isReaderModeLoadPending)
    }
}

fileprivate struct ReaderFileManagerModifier: ViewModifier {
    let ubiquityContainerIdentifier: String
    
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    
    func body(content: Content) -> some View {
        content
            .task(id: ubiquityContainerIdentifier) { @MainActor in
                readerModeViewModel.readerFileManager = ReaderFileManager.shared
                try? await ReaderFileManager.shared.initialize(ubiquityContainerIdentifier: ubiquityContainerIdentifier)
            }
    }
}

fileprivate struct ReaderNavigatorModifier: ViewModifier {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    
    func body(content: Content) -> some View {
        content
            .task { @MainActor in
                readerViewModel.navigator = navigator
                readerModeViewModel.bindDirectContentLoading(
                    readerContent: readerContent,
                    scriptCaller: readerViewModel.scriptCaller,
                    navigator: navigator
                )
            }
    }
}

@MainActor
func initializeReaderFontSizeIfNeeded(
    defaults: UserDefaults = .standard,
    defaultFontSize: CGFloat
) {
    // Launch arguments and registered defaults can be strings; fractional
    // reader sizes are valid too. Type conversion is not an absence check.
    guard defaults.object(forKey: "readerFontSize") == nil else { return }
    defaults.set(Int(round(defaultFontSize)), forKey: "readerFontSize")
}

fileprivate struct ReaderFontSizeModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var defaultFontSize: CGFloat = readerDefaultFontSizeBase()
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    
    func body(content: Content) -> some View {
        content
            .task { @MainActor in
                readerModeViewModel.defaultFontSize = defaultFontSize
                initializeReaderFontSizeIfNeeded(defaultFontSize: defaultFontSize)
            }
    }
}

public extension View {
    func readerEnvironment(ubiquityContainerIdentifier: String) -> some View {
        self
            .modifier(ReaderModeLoadPendingModifier())
            .modifier(ReaderViewModelModifier())
            .modifier(ReaderFileManagerModifier(ubiquityContainerIdentifier: ubiquityContainerIdentifier))
            .modifier(ReaderNavigatorModifier())
        .modifier(ReaderFontSizeModifier())
    }
}
