import SwiftUI

private struct ContentSelectionEnvironmentKey: EnvironmentKey {
    static let defaultValue: Binding<String?> = .constant(nil)
}

public extension EnvironmentValues {
    var contentSelection: Binding<String?> {
        get { self[ContentSelectionEnvironmentKey.self] }
        set { self[ContentSelectionEnvironmentKey.self] = newValue }
    }
}
