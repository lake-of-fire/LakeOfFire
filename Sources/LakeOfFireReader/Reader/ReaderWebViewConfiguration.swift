import SwiftUI
import SwiftUIWebView

public typealias ReaderWebViewConfigurationTransform = @Sendable (WebViewConfig) -> WebViewConfig
public typealias ReaderWebViewMessageHandlersTransform = @MainActor (WebViewMessageHandlers, WebViewScriptCaller) -> WebViewMessageHandlers

private struct ReaderWebViewConfigurationTransformKey: EnvironmentKey {
    static let defaultValue: ReaderWebViewConfigurationTransform = { $0 }
}

private struct ReaderWebViewMessageHandlersTransformKey: EnvironmentKey {
    static let defaultValue: ReaderWebViewMessageHandlersTransform = { handlers, _ in handlers }
}

public extension EnvironmentValues {
    var readerWebViewConfigurationTransform: ReaderWebViewConfigurationTransform {
        get { self[ReaderWebViewConfigurationTransformKey.self] }
        set { self[ReaderWebViewConfigurationTransformKey.self] = newValue }
    }

    var readerWebViewMessageHandlersTransform: ReaderWebViewMessageHandlersTransform {
        get { self[ReaderWebViewMessageHandlersTransformKey.self] }
        set { self[ReaderWebViewMessageHandlersTransformKey.self] = newValue }
    }
}
