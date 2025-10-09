import SwiftUI

private struct LookupsNavigationContextKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var isLookupsNavigationContext: Bool {
        get { self[LookupsNavigationContextKey.self] }
        set { self[LookupsNavigationContextKey.self] = newValue }
    }
}

public extension View {
    func lookupsNavigationContext(_ value: Bool) -> some View {
        environment(\.isLookupsNavigationContext, value)
    }
}
