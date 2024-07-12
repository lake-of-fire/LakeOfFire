import SwiftUI
import SwiftUIWebView

struct ReaderWebViewStateKey: EnvironmentKey {
    static let defaultValue: WebViewState = .empty
}

struct IsReaderModeLoadPendingKey: EnvironmentKey {
    static let defaultValue: @MainActor (any ReaderContentProtocol) -> Bool = { _ in false }
}

struct RefreshSettingsInReaderKey: EnvironmentKey {
    static let defaultValue: @MainActor (any ReaderContentProtocol, WebViewState?) -> Void = { _, _ in }
}

public extension EnvironmentValues {
    var readerWebViewState: WebViewState {
        get { self[ReaderWebViewStateKey.self] }
        set { self[ReaderWebViewStateKey.self] = newValue }
    }
    var isReaderModeLoadPending: @MainActor (any ReaderContentProtocol) -> Bool {
        get { self[IsReaderModeLoadPendingKey.self] }
        set { self[IsReaderModeLoadPendingKey.self] = newValue }
    }
    var refreshSettingsInReader: @MainActor (any ReaderContentProtocol, WebViewState?) -> Void {
        get { self[RefreshSettingsInReaderKey.self] }
        set { self[RefreshSettingsInReaderKey.self] = newValue }
    }
}

public struct ReaderEnvironmentViewModifier: ViewModifier {
    let ubiquityContainerIdentifier: String
    
    public init(ubiquityContainerIdentifier: String) {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
    }
    
    @ScaledMetric(relativeTo: .body) internal var defaultFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body) + 2 // Keep in sync with ReaderSettings defaultFontSize
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    
    public func body(content: Content) -> some View {
        content
            .environment(\.readerWebViewState, readerViewModel.state)
            .environment(\.refreshSettingsInReader, readerViewModel.refreshSettingsInWebView)
            .environment(\.isReaderModeLoadPending, readerModeViewModel.isReaderModeLoadPending)
            .environmentObject(readerViewModel.scriptCaller)
            .task { @MainActor in
                try? await readerFileManager.initialize(ubiquityContainerIdentifier: ubiquityContainerIdentifier)
                readerModeViewModel.readerFileManager = readerFileManager
                readerViewModel.navigator = navigator
                readerModeViewModel.navigator = navigator
                readerModeViewModel.scriptCaller = readerViewModel.scriptCaller
                readerModeViewModel.defaultFontSize = defaultFontSize
            }
    }
}

public extension View {
    func readerEnvironment(ubiquityContainerIdentifier: String) -> some View {
        modifier(ReaderEnvironmentViewModifier(ubiquityContainerIdentifier: ubiquityContainerIdentifier))
    }
}
