import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class LibraryCategoryFeedCreationOwnershipTests: XCTestCase {
    @MainActor
    func testCreationAndSelectionUseTheSelectedCategoryRealm() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let categoryID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 95_000)
        let libraryID = try await Self.insertCategory(
            id: categoryID, createdAt: createdAt, configuration: configurationA
        )
        try await Self.insertCategory(id: categoryID, createdAt: createdAt, configuration: configurationB)
        let originalLibraryConfiguration = LibraryDataManager.realmConfiguration
        let originalFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        LibraryDataManager.realmConfiguration = configurationB
        ReaderContentLoader.feedEntryRealmConfiguration = configurationB
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedConfiguration
        }
        let realm = try await Realm.open(configuration: configurationA)
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID))
        var selectedFeed: Feed?
        let viewModel = LibraryCategoryViewModel(
            category: category,
            libraryConfiguration: library,
            selectedFeed: Binding(get: { selectedFeed }, set: { selectedFeed = $0 })
        )

        let result = try await viewModel.createFeed()
        let feedID = try XCTUnwrap(result)

        XCTAssertEqual(selectedFeed?.id, feedID)
        XCTAssertEqual(selectedFeed?.categoryID, categoryID)
        XCTAssertEqual(selectedFeed?.realm?.configuration.inMemoryIdentifier, configurationA.inMemoryIdentifier)
        try await { @RealmBackgroundActor in
            let realmA = try await RealmBackgroundActor.shared.cachedRealm(for: configurationA)
            let realmB = try await RealmBackgroundActor.shared.cachedRealm(for: configurationB)
            let feed = try XCTUnwrap(realmA.object(ofType: Feed.self, forPrimaryKey: feedID))
            XCTAssertEqual(feed.meaningfulContentMinLength, 0)
            XCTAssertEqual(realmA.objects(Feed.self).count, 1)
            XCTAssertEqual(realmB.objects(Feed.self).count, 0)
            XCTAssertNotNil(realmA.object(
                ofType: BigSyncPendingMutation.self,
                forPrimaryKey: Feed.className() + "." + feedID.uuidString
            ))
            XCTAssertTrue(realmB.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    func testCreationRejectsADeletedOrReplacedCategoryWithoutJournaling() async throws {
        let configuration = makeConfiguration()
        let categoryID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 95_010)
        try await Self.insertCategory(id: categoryID, createdAt: createdAt, configuration: configuration)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            try await realm.asyncWrite {
                category.isDeleted = true
            }
        }()

        let deletedResult = try await LibraryDataManager.shared.createEmptyFeed(
            categoryID: categoryID, categoryCreatedAt: createdAt, realmConfiguration: configuration
        )
        XCTAssertNil(deletedResult)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            try await realm.asyncWrite {
                category.isDeleted = false
                category.createdAt = createdAt.addingTimeInterval(1)
            }
        }()
        let replacedResult = try await LibraryDataManager.shared.createEmptyFeed(
            categoryID: categoryID, categoryCreatedAt: createdAt, realmConfiguration: configuration
        )
        XCTAssertNil(replacedResult)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertTrue(realm.objects(Feed.self).isEmpty)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    @RealmBackgroundActor
    @discardableResult
    private static func insertCategory(
        id: UUID,
        createdAt: Date,
        configuration: Realm.Configuration
    ) async throws -> UUID {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        category.id = id
        category.createdAt = createdAt
        let library = LibraryConfiguration()
        library.categoryIDs.append(id)
        try await realm.asyncWrite {
            realm.add([category, library])
        }
        return library.id
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
