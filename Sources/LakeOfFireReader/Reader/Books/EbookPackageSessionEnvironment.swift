import SwiftUI
import LakeOfFireContent
import SwiftUIWebView

private struct ReaderEBookPackageSessionsKey: EnvironmentKey {
    static let defaultValue: ReaderEBookServingSessionStore? = nil
}

/// Result of native opening preparation for one exact WebView document. The
/// session capability addresses viewer bytes only; it is not reading mutation
/// authority.
public struct ReaderEBookPreparedOpen: Sendable, Equatable {
    public let packageSessionID: String?

    public init(packageSessionID: String?) throws {
        if let packageSessionID,
           !ReaderEBookServingSessionStore.isCanonicalSessionID(
                packageSessionID
           ) {
            throw ReaderEBookServingError.unavailableSession
        }
        self.packageSessionID = packageSessionID
    }
}

/// Called before the viewer receives its restore locator or starts package
/// loading. Implementations may suspend while capturing immutable bytes and
/// resolving reading identity. Returning is not enough: the caller repeats the
/// exact native binding check before publishing any result into JavaScript.
public typealias ReaderEBookOpeningPreparer = @MainActor @Sendable (
    _ backingURL: URL,
    _ javaScriptBindingToken:
        WebViewScriptCaller.JavaScriptBindingToken
) async throws -> ReaderEBookPreparedOpen

private struct ReaderEBookOpeningPreparerKey: EnvironmentKey {
    static let defaultValue: ReaderEBookOpeningPreparer? = nil
}

/// Task-local bridge only for synchronous ownership lookup in the application
/// restore loader. It does not grant file or Article authority. Core resolves
/// the token against its own per-reader registry and final Realm fences.
public enum ReaderEBookOpeningDocumentContext {
    @TaskLocal public static var javaScriptBindingToken:
        WebViewScriptCaller.JavaScriptBindingToken?
}

public extension EnvironmentValues {
    var readerEBookPackageSessions: ReaderEBookServingSessionStore? {
        get { self[ReaderEBookPackageSessionsKey.self] }
        set { self[ReaderEBookPackageSessionsKey.self] = newValue }
    }

    var readerEBookOpeningPreparer: ReaderEBookOpeningPreparer? {
        get { self[ReaderEBookOpeningPreparerKey.self] }
        set { self[ReaderEBookOpeningPreparerKey.self] = newValue }
    }
}

public extension View {
    /// Supply the same native store into which the opening coordinator installs
    /// its verified package; then pass the returned lease ID to loadEBook.
    func readerEBookPackageSessions(
        _ sessions: ReaderEBookServingSessionStore
    ) -> some View {
        environment(\.readerEBookPackageSessions, sessions)
    }

    /// Prepare one document before its first restore/package request. This is a
    /// per-reader environment boundary, never a process-global URL registry.
    func readerEBookOpeningPreparer(
        _ preparer: @escaping ReaderEBookOpeningPreparer
    ) -> some View {
        environment(\.readerEBookOpeningPreparer, preparer)
    }
}
