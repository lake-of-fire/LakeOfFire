import SwiftUI
@preconcurrency import WebKit

public typealias ReaderNavigationActionHandler = @Sendable (WKNavigationAction) async -> WKNavigationActionPolicy?
public typealias ReaderNavigationActionContextHandler = @Sendable (ReaderNavigationActionContext) async -> WKNavigationActionPolicy?

public struct ReaderNavigationActionContext: @unchecked Sendable {
    public let action: WKNavigationAction
    public let websiteDataStore: WKWebsiteDataStore

    public init(action: WKNavigationAction, websiteDataStore: WKWebsiteDataStore) {
        self.action = action
        self.websiteDataStore = websiteDataStore
    }
}

private struct ReaderNavigationActionHandlerKey: EnvironmentKey {
    static let defaultValue: ReaderNavigationActionHandler? = nil
}

private struct ReaderNavigationActionContextHandlerKey: EnvironmentKey {
    static let defaultValue: ReaderNavigationActionContextHandler? = nil
}

private struct ReaderWebViewDataStoreKey: EnvironmentKey {
    static let defaultValue: WKWebsiteDataStore? = nil
}

public struct ReaderNativeViewContext {
    public let pageURL: URL
    public let contentURL: URL?
    public let bottomSafeAreaInset: CGFloat

    public init(
        pageURL: URL,
        contentURL: URL?,
        bottomSafeAreaInset: CGFloat = 0
    ) {
        self.pageURL = pageURL
        self.contentURL = contentURL
        self.bottomSafeAreaInset = bottomSafeAreaInset
    }
}

public struct ReaderNativeViewProvider: @unchecked Sendable {
    private let canHandleURL: @MainActor @Sendable (URL) -> Bool
    private let makeView: @MainActor @Sendable (ReaderNativeViewContext) -> AnyView?

    public init(
        canHandle: @escaping @MainActor @Sendable (URL) -> Bool,
        makeView: @escaping @MainActor @Sendable (ReaderNativeViewContext) -> AnyView?
    ) {
        self.canHandleURL = canHandle
        self.makeView = makeView
    }

    @MainActor
    public func canHandle(_ url: URL) -> Bool {
        canHandleURL(url)
    }

    @MainActor
    public func view(for context: ReaderNativeViewContext) -> AnyView? {
        makeView(context)
    }
}

private struct ReaderNativeViewProviderKey: EnvironmentKey {
    static let defaultValue: ReaderNativeViewProvider? = nil
}

public extension EnvironmentValues {
    var readerNavigationActionHandler: ReaderNavigationActionHandler? {
        get { self[ReaderNavigationActionHandlerKey.self] }
        set { self[ReaderNavigationActionHandlerKey.self] = newValue }
    }

    var readerNavigationActionContextHandler: ReaderNavigationActionContextHandler? {
        get { self[ReaderNavigationActionContextHandlerKey.self] }
        set { self[ReaderNavigationActionContextHandlerKey.self] = newValue }
    }

    var readerWebViewDataStore: WKWebsiteDataStore? {
        get { self[ReaderWebViewDataStoreKey.self] }
        set { self[ReaderWebViewDataStoreKey.self] = newValue }
    }

    var readerNativeViewProvider: ReaderNativeViewProvider? {
        get { self[ReaderNativeViewProviderKey.self] }
        set { self[ReaderNativeViewProviderKey.self] = newValue }
    }
}

public extension View {
    func readerNavigationActionHandler(_ handler: ReaderNavigationActionHandler?) -> some View {
        environment(\.readerNavigationActionHandler, handler)
    }

    /// Handles navigation with the exact data store used by the Reader web
    /// view. Returning nil falls back to the action-only handler, if present.
    func readerNavigationActionContextHandler(
        _ handler: ReaderNavigationActionContextHandler?
    ) -> some View {
        environment(\.readerNavigationActionContextHandler, handler)
    }

    /// Supplies the data store used by Reader's web view and navigation context.
    func readerWebViewDataStore(_ dataStore: WKWebsiteDataStore?) -> some View {
        environment(\.readerWebViewDataStore, dataStore)
    }

    func readerNativeViewProvider(_ provider: ReaderNativeViewProvider?) -> some View {
        environment(\.readerNativeViewProvider, provider)
    }
}
