import SwiftUI

private struct ReaderEnvironmentIsolationKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var isReaderEnvironmentIsolated: Bool {
        get { self[ReaderEnvironmentIsolationKey.self] }
        set { self[ReaderEnvironmentIsolationKey.self] = newValue }
    }
}

public extension View {
    func readerEnvironmentIsolated(_ value: Bool) -> some View {
        environment(\.isReaderEnvironmentIsolated, value)
    }
}
