import SwiftUI
import Foundation

private struct ContentSelectionEnvironmentKey: EnvironmentKey {
    static let defaultValue: Binding<String?> = .constant(nil)
}

public extension EnvironmentValues {
    var contentSelection: Binding<String?> {
        get { self[ContentSelectionEnvironmentKey.self] }
        set { self[ContentSelectionEnvironmentKey.self] = newValue }
    }
}

public typealias ContentSelectionNavigationHint = @Sendable (_ url: URL, _ selectionKey: String) -> Void

private struct ContentSelectionNavigationHintKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: ContentSelectionNavigationHint? = nil
}

public extension EnvironmentValues {
    var contentSelectionNavigationHint: ContentSelectionNavigationHint? {
        get { self[ContentSelectionNavigationHintKey.self] }
        set { self[ContentSelectionNavigationHintKey.self] = newValue }
    }
}
