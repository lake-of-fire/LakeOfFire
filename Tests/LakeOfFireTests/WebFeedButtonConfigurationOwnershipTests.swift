import BigSyncKit
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class WebFeedButtonConfigurationOwnershipTests: XCTestCase {
    @MainActor
    func testWebFeedObservationPublishesFromItsRequestedRealm() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let identifiers = try await Self.insertLibrary(in: configurationA, title: "A")
        try await Self.insertLibrary(in: configurationB, title: "B", identifiers: identifiers)
        let originalConfiguration = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configurationB
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }
        let published = expectation(description: "Categories resolve in the observing Realm")
        let state = WebFeedButtonLibraryState(realmConfiguration: configurationA)
        var didFulfill = false
        let subscription = state.$userCategories.sink { categories in
            guard categories?.first?.title == "A", !didFulfill else { return }
            didFulfill = true
            published.fulfill()
        }
        defer { subscription.cancel() }

        state.startIfNeeded()

        await fulfillment(of: [published], timeout: 5)
        XCTAssertEqual(state.libraryConfiguration?.realm?.configuration.inMemoryIdentifier,
                       configurationA.inMemoryIdentifier)
        XCTAssertEqual(state.userCategories?.map(\.title), ["A"])
    }

    private struct Identifiers: Sendable {
        let libraryID: UUID
        let categoryID: UUID
        let scriptID: UUID
        let createdAt: Date
    }

    @RealmBackgroundActor
    @discardableResult
    private static func insertLibrary(
        in configuration: Realm.Configuration,
        title: String,
        identifiers: Identifiers? = nil
    ) async throws -> Identifiers {
        let identifiers = identifiers ?? Identifiers(
            libraryID: UUID(), categoryID: UUID(), scriptID: UUID(), createdAt: Date()
        )
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let library = LibraryConfiguration()
        library.id = identifiers.libraryID
        library.createdAt = identifiers.createdAt
        library.categoryIDs.append(identifiers.categoryID)
        library.userScriptIDs.append(identifiers.scriptID)
        let category = FeedCategory()
        category.id = identifiers.categoryID
        category.createdAt = identifiers.createdAt
        category.title = title
        let script = UserScript()
        script.id = identifiers.scriptID
        script.createdAt = identifiers.createdAt
        script.title = title + " script"
        try await realm.asyncWrite {
            realm.add([library, category, script])
        }
        return identifiers
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self, Feed.self,
            UserScript.self, UserScriptAllowedDomain.self, BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }
}
