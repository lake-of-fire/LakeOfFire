import SwiftUI
import LakeOfFireContent

private struct ReaderEBookPackageSessionsKey: EnvironmentKey {
    static let defaultValue: ReaderEBookServingSessionStore? = nil
}

public extension EnvironmentValues {
    var readerEBookPackageSessions: ReaderEBookServingSessionStore? {
        get { self[ReaderEBookPackageSessionsKey.self] }
        set { self[ReaderEBookPackageSessionsKey.self] = newValue }
    }
}

public extension View {
    /// Supply the same native store into which the opening coordinator installs
    /// its verified package; then pass the returned lease ID to loadEBook.
    func readerEBookPackageSessions(_ sessions: ReaderEBookServingSessionStore) -> some View {
        environment(\.readerEBookPackageSessions, sessions)
    }
}
