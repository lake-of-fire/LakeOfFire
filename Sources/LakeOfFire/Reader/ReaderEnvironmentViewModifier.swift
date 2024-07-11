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
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    
    public func body(content: Content) -> some View {
        content
            .environment(\.readerWebViewState, readerViewModel.state)
            .environment(\.isReaderModeLoadPending, readerViewModel.isReaderModeLoadPending)
            .environment(\.refreshSettingsInReader, readerViewModel.refreshSettingsInWebView)
            .environmentObject(readerViewModel.scriptCaller)
            .task { @MainActor in
                try? await readerFileManager.initialize(ubiquityContainerIdentifier: ubiquityContainerIdentifier)
                readerViewModel.readerFileManager = readerFileManager
                readerViewModel.navigator = navigator
            }
    }
}

public extension View {
    func readerEnvironment(ubiquityContainerIdentifier: String) -> some View {
        modifier(ReaderEnvironmentViewModifier(ubiquityContainerIdentifier: ubiquityContainerIdentifier))
    }
}
