import SwiftUI

private struct ContentBlockingRulesKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct ContentBlockingEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ContentBlockingStatsModelKey: EnvironmentKey {
    static let defaultValue: AdblockStatsModel? = nil
}

public extension EnvironmentValues {
    var contentBlockingRules: String? {
        get { self[ContentBlockingRulesKey.self] }
        set { self[ContentBlockingRulesKey.self] = newValue }
    }

    var contentBlockingEnabled: Bool {
        get { self[ContentBlockingEnabledKey.self] }
        set { self[ContentBlockingEnabledKey.self] = newValue }
    }

    var contentBlockingStatsModel: AdblockStatsModel? {
        get { self[ContentBlockingStatsModelKey.self] }
        set { self[ContentBlockingStatsModelKey.self] = newValue }
    }
}
