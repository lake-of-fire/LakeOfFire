import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class LibraryMountedCategoryEditorTests: XCTestCase {
    @MainActor
    func testClosingEditorFlushesTheLatestDraftIntoItsOwningRealm() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let identifiers = try await Self.insertCategory(in: configurationA, title: "A")
        try await Self.insertCategory(in: configurationB, title: "B", identifiers: identifiers)
        let realmA = try await Realm.open(configuration: configurationA)
        let realmB = try await Realm.open(configuration: configurationB)
        let categoryA = try XCTUnwrap(realmA.object(ofType: FeedCategory.self,
                                                   forPrimaryKey: identifiers.categoryID))
        let libraryB = try XCTUnwrap(realmB.object(ofType: LibraryConfiguration.self,
                                                  forPrimaryKey: identifiers.libraryID))
        let model = LibraryCategoryViewModel(category: categoryA, libraryConfiguration: libraryB,
                                             selectedFeed: .constant(nil))
        model.categoryTitle = "First draft"
        model.categoryTitle = "Final draft"
        model.categoryBackgroundImageURL = "https://example.com/final.jpg"
        model.refresh()
        XCTAssertEqual(model.categoryTitle, "Final draft")
        XCTAssertEqual(model.categoryBackgroundImageURL, "https://example.com/final.jpg")

        await model.finishEditing()

        XCTAssertNil(model.fieldSaveErrorMessage)
        XCTAssertEqual(model.pendingFieldSaveCount, 0)
        try await { @RealmBackgroundActor in
            let realmA = try await RealmBackgroundActor.shared.cachedRealm(for: configurationA)
            let realmB = try await RealmBackgroundActor.shared.cachedRealm(for: configurationB)
            let savedA = try XCTUnwrap(realmA.object(ofType: FeedCategory.self,
                                                    forPrimaryKey: identifiers.categoryID))
            XCTAssertEqual(savedA.title, "Final draft")
            XCTAssertEqual(savedA.backgroundImageUrl.absoluteString, "https://example.com/final.jpg")
            XCTAssertEqual(realmB.object(ofType: FeedCategory.self,
                                         forPrimaryKey: identifiers.categoryID)?.title, "B")
        }()
    }

    @MainActor
    func testInFlightOlderSaveCannotFinishAfterTheLatestIntent() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertCategory(in: configuration, title: "Original")
        let realm = try await Realm.open(configuration: configuration)
        let model = try makeModel(in: realm, identifiers: identifiers)
        let entered = expectation(description: "Older save reached the command boundary")
        let gate = SaveGate()
        defer { Task { await gate.release() } }
        LibraryCategoryFieldCommand.beforeWriteTestHook = { field, value in
            if field == .title, value == "Older" {
                entered.fulfill()
                await gate.wait()
            }
        }
        defer { LibraryCategoryFieldCommand.beforeWriteTestHook = nil }
        model.categoryTitle = "Older"
        await fulfillment(of: [entered], timeout: 5)
        model.categoryTitle = "Latest"
        model.refresh()
        XCTAssertEqual(model.categoryTitle, "Latest")
        await gate.release()

        await model.finishEditing()

        XCTAssertNil(model.fieldSaveErrorMessage)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertEqual(realm.object(ofType: FeedCategory.self,
                                         forPrimaryKey: identifiers.categoryID)?.title, "Latest")
        }()
    }

    @MainActor
    func testSupersededSaveFailureDoesNotReplaceTheLatestSuccessfulPresentation() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertCategory(in: configuration, title: "Original")
        let realm = try await Realm.open(configuration: configuration)
        let model = try makeModel(in: realm, identifiers: identifiers)
        let entered = expectation(description: "Rejected save reached the command boundary")
        let gate = SaveGate()
        defer { Task { await gate.release() } }
        LibraryCategoryFieldCommand.beforeWriteTestHook = { field, value in
            if field == .title, value == "Rejected" {
                entered.fulfill()
                await gate.wait()
                throw SaveFailure.rejected
            }
        }
        defer { LibraryCategoryFieldCommand.beforeWriteTestHook = nil }
        model.categoryTitle = "Rejected"
        await fulfillment(of: [entered], timeout: 5)
        model.categoryTitle = "Accepted"
        await gate.release()

        await model.finishEditing()

        XCTAssertNil(model.fieldSaveErrorMessage)
        XCTAssertEqual(model.categoryTitle, "Accepted")
        XCTAssertEqual(model.pendingFieldSaveCount, 0)
    }

    @MainActor
    func testInvalidImageDraftSurvivesRefreshWithoutChangingStoredImage() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertCategory(in: configuration, title: "Original")
        let realm = try await Realm.open(configuration: configuration)
        let model = try makeModel(in: realm, identifiers: identifiers)
        // Both intents are captured before the queued save gets an actor turn.
        model.categoryBackgroundImageURL = "https://example.com/pending.jpg"
        model.categoryBackgroundImageURL = "not-a-complete-url"
        model.refresh()
        XCTAssertEqual(model.categoryBackgroundImageURL, "not-a-complete-url")
        XCTAssertNotNil(model.fieldSaveErrorMessage)

        await model.finishEditing()

        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertEqual(realm.object(ofType: FeedCategory.self,
                                         forPrimaryKey: identifiers.categoryID)?.backgroundImageUrl.absoluteString,
                           "about:blank")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }()
    }

    @MainActor
    func testFailedRequestIsNotRetriedByRepeatedRetirementFlush() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertCategory(in: configuration, title: "Original")
        let realm = try await Realm.open(configuration: configuration)
        let model = try makeModel(in: realm, identifiers: identifiers)
        let attempts = SaveAttempts()
        LibraryCategoryFieldCommand.beforeWriteTestHook = { _, _ in
            await attempts.record()
            throw SaveFailure.rejected
        }
        defer { LibraryCategoryFieldCommand.beforeWriteTestHook = nil }
        model.categoryTitle = "Rejected draft"
        await model.finishEditing()
        XCTAssertNotNil(model.fieldSaveErrorMessage)
        model.refresh()
        XCTAssertEqual(model.categoryTitle, "Rejected draft")

        model.flushPendingFieldDrafts()
        await model.finishEditing()

        let count = await attempts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.pendingFieldSaveCount, 0)
    }

    @MainActor
    func testSameIDReplacementCannotReceiveTheRetainedDraft() async throws {
        let configuration = makeConfiguration()
        let identifiers = try await Self.insertCategory(in: configuration, title: "Original")
        let realm = try await Realm.open(configuration: configuration)
        let model = try makeModel(in: realm, identifiers: identifiers)
        let entered = expectation(description: "Draft reached the command boundary")
        let gate = SaveGate()
        defer { Task { await gate.release() } }
        LibraryCategoryFieldCommand.beforeWriteTestHook = { field, value in
            if field == .title, value == "Stale draft" {
                entered.fulfill()
                await gate.wait()
            }
        }
        defer { LibraryCategoryFieldCommand.beforeWriteTestHook = nil }
        model.categoryTitle = "Stale draft"
        await fulfillment(of: [entered], timeout: 5)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let original = try XCTUnwrap(realm.object(ofType: FeedCategory.self,
                                                       forPrimaryKey: identifiers.categoryID))
            let replacement = FeedCategory()
            replacement.id = identifiers.categoryID
            replacement.createdAt = identifiers.createdAt.addingTimeInterval(1)
            replacement.title = "Replacement"
            try await realm.asyncWrite {
                realm.delete(original)
                realm.add(replacement)
            }
        }()
        await gate.release()

        await model.finishEditing()

        XCTAssertNotNil(model.fieldSaveErrorMessage)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertEqual(realm.object(ofType: FeedCategory.self,
                                         forPrimaryKey: identifiers.categoryID)?.title, "Replacement")
        }()
    }

    @MainActor
    private func makeModel(in realm: Realm, identifiers: Identifiers) throws -> LibraryCategoryViewModel {
        LibraryCategoryViewModel(
            category: try XCTUnwrap(realm.object(ofType: FeedCategory.self,
                                                forPrimaryKey: identifiers.categoryID)),
            libraryConfiguration: try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self,
                                                            forPrimaryKey: identifiers.libraryID)),
            selectedFeed: .constant(nil)
        )
    }

    private struct Identifiers: Sendable {
        let categoryID: UUID
        let libraryID: UUID
        let createdAt: Date
    }

    @RealmBackgroundActor
    @discardableResult
    private static func insertCategory(
        in configuration: Realm.Configuration,
        title: String,
        identifiers: Identifiers? = nil
    ) async throws -> Identifiers {
        let identifiers = identifiers ?? Identifiers(categoryID: UUID(), libraryID: UUID(), createdAt: Date())
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let category = FeedCategory()
        category.id = identifiers.categoryID
        category.createdAt = identifiers.createdAt
        category.title = title
        let library = LibraryConfiguration()
        library.id = identifiers.libraryID
        library.createdAt = identifiers.createdAt
        library.categoryIDs.append(category.id)
        try await realm.asyncWrite { realm.add([category, library]) }
        return identifiers
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self,
                                     Feed.self, UserScript.self, UserScriptAllowedDomain.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private enum SaveFailure: Error { case rejected }

    private actor SaveAttempts {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private actor SaveGate {
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }
}
