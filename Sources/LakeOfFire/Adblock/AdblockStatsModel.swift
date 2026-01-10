import Foundation
import BraveAdblock
import OrderedCollections
import SwiftUI

public struct AdblockStatsCandidate: Hashable, Sendable {
    public let requestURL: URL
    public let sourceURL: URL
    public let resourceType: AdblockResourceType

    public init(requestURL: URL, sourceURL: URL, resourceType: AdblockResourceType) {
        self.requestURL = requestURL
        self.sourceURL = sourceURL
        self.resourceType = resourceType
    }
}

public struct AdblockBlockedRequest: Hashable, Identifiable, Sendable {
    public let requestURL: URL
    public let sourceURL: URL
    public let resourceType: AdblockResourceType

    public init(requestURL: URL, sourceURL: URL, resourceType: AdblockResourceType) {
        self.requestURL = requestURL
        self.sourceURL = sourceURL
        self.resourceType = resourceType
    }

    public var id: String {
        "\(resourceType.rawValue)|\(sourceURL.absoluteString)|\(requestURL.absoluteString)"
    }
}

@MainActor
public final class AdblockStatsModel: ObservableObject {
    @Published public private(set) var blockedCount = 0
    @Published public private(set) var blockedRequests: [AdblockBlockedRequest] = []
    @Published public private(set) var pageURL: URL? = nil

    private let evaluator = AdblockStatsEvaluator()
    private var shouldIgnoreNextNavigation = false
    private var isTrackingEnabledForPage = true

    public init() {}

    public func updateRules(_ rules: String?) async {
        await evaluator.updateRules(rules)
    }

    public func ignoreNextNavigation() {
        shouldIgnoreNextNavigation = true
    }

    public func beginPage(url: URL?) {
        pageURL = url
        blockedCount = 0
        blockedRequests = []

        if shouldIgnoreNextNavigation {
            isTrackingEnabledForPage = false
            shouldIgnoreNextNavigation = false
        } else {
            isTrackingEnabledForPage = true
        }
    }

    public func handleCandidates(
        _ candidates: [AdblockStatsCandidate],
        pageURL: URL?,
        isContentBlockingEnabled: Bool
    ) async {
        guard isContentBlockingEnabled, isTrackingEnabledForPage else { return }
        guard !candidates.isEmpty else { return }

        if let currentHost = self.pageURL?.host,
           let candidateHost = pageURL?.host,
           currentHost != candidateHost {
            return
        }

        let blocked = await evaluator.evaluate(candidates: candidates)
        guard !blocked.isEmpty else { return }

        var updated = OrderedSet(blockedRequests)
        for entry in blocked {
            updated.append(entry)
        }
        let newList = Array(updated)
        if newList.count != blockedRequests.count {
            blockedRequests = newList
            blockedCount = newList.count
        }
    }

    public static func candidates(from messageBody: Any) -> [AdblockStatsCandidate]? {
        guard let payload = messageBody as? [String: Any],
              let data = payload["data"] as? [[String: Any]]
        else {
            return nil
        }

        var candidates: [AdblockStatsCandidate] = []
        candidates.reserveCapacity(data.count)

        for item in data {
            guard let resourceURLString = item["resourceURL"] as? String,
                  let sourceURLString = item["sourceURL"] as? String,
                  let resourceTypeString = item["resourceType"] as? String,
                  let resourceType = AdblockResourceType(rawValue: resourceTypeString),
                  let requestURL = URL(string: resourceURLString),
                  let sourceURL = URL(string: sourceURLString)
            else {
                continue
            }

            candidates.append(
                AdblockStatsCandidate(
                    requestURL: requestURL,
                    sourceURL: sourceURL,
                    resourceType: resourceType
                )
            )
        }

        return candidates
    }
}

actor AdblockStatsEvaluator {
    private var engine: BraveAdblockEngine?
    private var activeRules: String?

    func updateRules(_ rules: String?) {
        guard let rules, !rules.isEmpty else {
            engine = nil
            activeRules = nil
            return
        }
        guard activeRules != rules else { return }

        do {
            engine = try BraveAdblockEngine(rules: rules)
            activeRules = rules
        } catch {
            engine = nil
            activeRules = nil
            print("# AdblockStatsEvaluator.updateRules failed: \(error)")
        }
    }

    func evaluate(candidates: [AdblockStatsCandidate]) -> [AdblockBlockedRequest] {
        guard let engine else { return [] }

        var blocked: [AdblockBlockedRequest] = []
        blocked.reserveCapacity(candidates.count)

        for candidate in candidates {
            if engine.shouldBlock(
                requestURL: candidate.requestURL,
                sourceURL: candidate.sourceURL,
                resourceType: candidate.resourceType,
                isAggressive: false
            ) {
                blocked.append(
                    AdblockBlockedRequest(
                        requestURL: candidate.requestURL,
                        sourceURL: candidate.sourceURL,
                        resourceType: candidate.resourceType
                    )
                )
            }
        }

        return blocked
    }
}
