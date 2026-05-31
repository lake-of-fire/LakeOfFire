import SwiftUI
@preconcurrency import WebKit

public typealias ReaderNavigationActionHandler = (WKNavigationAction) async -> WKNavigationActionPolicy?

private struct ReaderNavigationActionHandlerKey: EnvironmentKey {
    static let defaultValue: ReaderNavigationActionHandler? = nil
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

public struct ReaderNativeViewProvider {
    private let canHandleURL: @MainActor (URL) -> Bool
    private let makeView: @MainActor (ReaderNativeViewContext) -> AnyView?

    public init(
        canHandle: @escaping @MainActor (URL) -> Bool,
        makeView: @escaping @MainActor (ReaderNativeViewContext) -> AnyView?
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

    var readerNativeViewProvider: ReaderNativeViewProvider? {
        get { self[ReaderNativeViewProviderKey.self] }
        set { self[ReaderNativeViewProviderKey.self] = newValue }
    }
}

public extension View {
    func readerNavigationActionHandler(_ handler: ReaderNavigationActionHandler?) -> some View {
        environment(\.readerNavigationActionHandler, handler)
    }

    func readerNativeViewProvider(_ provider: ReaderNativeViewProvider?) -> some View {
        environment(\.readerNativeViewProvider, provider)
    }
}
