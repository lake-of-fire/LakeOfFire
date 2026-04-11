import SwiftUI
import SwiftUIWebView

public struct WebViewNavigatorEnvironmentKey: EnvironmentKey {
    nonisolated(unsafe) public static var defaultValue = WebViewNavigator()
}

public extension EnvironmentValues {
    var webViewNavigator: WebViewNavigator {
        get { self[WebViewNavigatorEnvironmentKey.self] }
        set { self[WebViewNavigatorEnvironmentKey.self] = newValue }
    }
}
