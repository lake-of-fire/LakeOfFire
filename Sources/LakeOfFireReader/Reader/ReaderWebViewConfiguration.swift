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

private struct ReaderMediaLanguageIdentifierKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    var readerMediaLanguageIdentifier: String? {
        get { self[ReaderMediaLanguageIdentifierKey.self] }
        set { self[ReaderMediaLanguageIdentifierKey.self] = newValue }
    }

    var readerWebViewConfigurationTransform: ReaderWebViewConfigurationTransform {
        get { self[ReaderWebViewConfigurationTransformKey.self] }
        set { self[ReaderWebViewConfigurationTransformKey.self] = newValue }
    }

    var readerWebViewMessageHandlersTransform: ReaderWebViewMessageHandlersTransform {
        get { self[ReaderWebViewMessageHandlersTransformKey.self] }
        set { self[ReaderWebViewMessageHandlersTransformKey.self] = newValue }
    }
}

