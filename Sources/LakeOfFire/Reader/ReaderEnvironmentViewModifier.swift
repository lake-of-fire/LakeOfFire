import SwiftUI
import SwiftUIWebView

struct ReaderWebViewStateKey: EnvironmentKey {
    static let defaultValue: WebViewState = .empty
}

public extension EnvironmentValues {
    var readerWebViewState: WebViewState {
        get { self[ReaderWebViewStateKey.self] }
        set { self[ReaderWebViewStateKey.self] = newValue }
    }
}

struct WillReaderModeLoadKey: EnvironmentKey {
    static let defaultValue = Binding.constant(false)
}

public extension EnvironmentValues {
    var willReaderModeLoad: Binding<Bool> {
        get { self[WillReaderModeLoadKey.self] }
        set { self[WillReaderModeLoadKey.self] = newValue }
    }
}

struct RefreshSettingsInReaderKey: EnvironmentKey {
    static let defaultValue: @MainActor ((any ReaderContentModel)?, WebViewState?) -> Void = { _, _ in }
}

public extension EnvironmentValues {
    var refreshSettingsInReader: @MainActor ((any ReaderContentModel)?, WebViewState?) -> Void {
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
            .environment(\.willReaderModeLoad, $readerViewModel.willReaderModeLoad)
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
