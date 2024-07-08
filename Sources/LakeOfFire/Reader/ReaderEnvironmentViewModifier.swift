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
