import SwiftUI
import BraveAdblock

@MainActor
public final class AdblockRulesModel: ObservableObject {
    @Published public private(set) var contentRulesJSON: String? = nil
    @Published public private(set) var isTruncated = false
    @Published public private(set) var filterListRules: String? = nil
    @Published public private(set) var lastFetchedAt: Date? = nil
    @Published public private(set) var lastRefreshError: AdblockRulesRefreshError? = nil

    private let store: AdblockRulesStore

    public init(endpoint: AdblockListEndpoint = .braveDefault, cacheDirectory: URL? = nil) {
        self.store = AdblockRulesStore(endpoint: endpoint, cacheDirectory: cacheDirectory)
    }

    public func loadCachedRules() async {
        if let cached = await store.loadCachedContentRules() {
            contentRulesJSON = cached.contentRules.rulesJSON
            isTruncated = cached.contentRules.truncated
        }
        filterListRules = await store.loadCachedFilterList()
        lastFetchedAt = await store.loadLastFetchedAt()
        lastRefreshError = await store.loadLastRefreshError()
    }

    public func refreshContentRules() async {
        do {
            let result = try await store.refreshContentRules()
            contentRulesJSON = result.contentRules.rulesJSON
            isTruncated = result.contentRules.truncated
            filterListRules = await store.loadCachedFilterList()
            lastFetchedAt = await store.loadLastFetchedAt()
            lastRefreshError = nil
        } catch {
            let errorInfo = AdblockRulesRefreshError(
                message: error.localizedDescription,
                recordedAt: Date(),
                isConnectivityIssue: isConnectivityIssue(error)
            )
            lastRefreshError = errorInfo
            await store.recordRefreshError(errorInfo)
            print("# AdblockRulesModel.refreshContentRules failed: \(error)")
        }
    }

    public func refreshContentRules(ifEnabled isEnabled: Bool) async {
        guard isEnabled else { return }
        await refreshContentRules()
    }

    private func isConnectivityIssue(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .notConnectedToInternet
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == URLError.notConnectedToInternet.rawValue
        }
        return false
    }
}
