import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor CategoryFieldWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class LibraryCategoryFieldOwnershipTests: XCTestCase, @unchecked Sendable {
    private func fixture(id: UUID = UUID()) async throws -> (Realm, FeedCategory, LibraryConfiguration) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [FeedCategory.self, LibraryConfiguration.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try await Realm(configuration: captured, actor: MainActor.shared)
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: captured)
            try await writer.asyncWrite {
                let category = FeedCategory()
                category.id = id
                category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
                category.title = "Original"
                category.backgroundImageUrl = URL(string: "about:blank")!
                writer.add(category)
                category.refreshChangeMetadata(explicitlyModified: true)
                let library = LibraryConfiguration()
                library.categoryIDs.append(id)
                writer.add(library)
                library.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        realm.refresh()
        return (
            realm,
            try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: id)),
            try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
        )
    }

    private func model(_ category: FeedCategory, _ library: LibraryConfiguration) -> LibraryCategoryViewModel {
        LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil), observesRealm: false
        )
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
    }

    func testImmediateDonePreservesFinalBufferedTitleAndImage() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        editor.isEditing = true
        editor.categoryTitle = "Leading"
        editor.categoryTitle = "Final"
        editor.categoryBackgroundImageURL = "https://leading.example/image.png"
        editor.categoryBackgroundImageURL = "https://final.example/image.png"
        let completion = editor.finishEditing()
        editor.refresh()
        XCTAssertEqual(editor.categoryTitle, "Final")
        try await completion.value
        realm.refresh()
        XCTAssertEqual(category.title, "Final")
        XCTAssertEqual(category.backgroundImageUrl.absoluteString, "https://final.example/image.png")
    }

    func testHydrationAndRepeatedInputDoNotJournal() async throws {
        let (realm, category, library) = try await fixture()
        let before = generations(realm)
        let editor = model(category, library)
        editor.refresh()
        try await editor.finishEditing().value
        try await editor.writeFieldAsync(.title("Original")).value
        try await editor.writeFieldAsync(.imageURL("")).value
        realm.refresh()
        XCTAssertEqual(generations(realm), before)
    }

    func testOlderSuspendedWriteCannotOverwriteNewerInput() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "old write suspended")
        let oldWrite = editor.writeFieldAsync(.title("Old"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        defer { oldWrite.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        try await editor.writeFieldAsync(.title("Newest")).value
        realm.refresh()
        let before = generations(realm)
        await gate.release()
        try await oldWrite.value
        realm.refresh()
        XCTAssertEqual(category.title, "Newest")
        XCTAssertEqual(editor.categoryTitle, "Newest")
        XCTAssertEqual(generations(realm), before)
    }

    func testPendingWriteStaysInOriginalRealmWithIdenticalIDs() async throws {
        let (original, category, library) = try await fixture()
        let (replacement, otherCategory, otherLibrary) = try await fixture(id: category.id)
        let editor = model(category, library)
        try await editor.writeFieldAsync(.title("Original store edit")).value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(category.title, "Original store edit")
        XCTAssertEqual(otherCategory.title, "Original")
        XCTAssertNotEqual(
            LibraryCategoryEditorIdentity(category: category, library: library),
            LibraryCategoryEditorIdentity(category: otherCategory, library: otherLibrary)
        )
    }

    func testReopenedEditorSharesOrderingWithPendingOlderCommand() async throws {
        let (realm, category, library) = try await fixture()
        let firstEditor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "first editor suspended")
        let oldWrite = firstEditor.writeFieldAsync(.title("Old"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        defer { oldWrite.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let secondEditor = model(category, library)
        try await secondEditor.writeFieldAsync(.title("New editor")).value
        await gate.release()
        try await oldWrite.value
        realm.refresh()
        XCTAssertEqual(category.title, "New editor")
    }

    func testQueuedWriteRejectsNewManagedEligibility() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let id = category.id
        let configuration = realm.configuration
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "write suspended")
        let write = editor.writeFieldAsync(.title("Rejected"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        defer { write.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWrite {
                writer.object(ofType: FeedCategory.self, forPrimaryKey: id)?.opmlURL =
                    URL(string: "https://example.com/managed.opml")
            }
        }.value
        realm.refresh()
        let before = generations(realm)
        await gate.release()
        try await write.value
        realm.refresh()
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(editor.categoryTitle, "Original")
        XCTAssertEqual(generations(realm), before)
    }

    func testRetirementFlushesFinalBufferedDraft() async throws {
        let (realm, category, library) = try await fixture()
        var editor: LibraryCategoryViewModel? = model(category, library)
        editor?.isEditing = true
        editor?.categoryTitle = "Leading"
        editor?.categoryTitle = "Retired final"
        editor = nil
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            realm.refresh()
            if category.title == "Retired final" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(category.title, "Retired final")
    }

    func testEarlierUserValueCanReturnAfterHydration() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        try await editor.writeFieldAsync(.title("User value")).value
        let configuration = realm.configuration
        let id = category.id
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWrite {
                writer.object(ofType: FeedCategory.self, forPrimaryKey: id)?.title = "External value"
            }
        }.value
        editor.refresh()
        XCTAssertEqual(editor.categoryTitle, "External value")
        editor.categoryTitle = "User value"
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(category.title, "User value")
    }

    func testQueuedWriteRejectsSameIDNewIncarnation() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let id = category.id
        let configuration = realm.configuration
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "write suspended")
        let write = editor.writeFieldAsync(.title("Retired draft"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        defer { write.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWrite {
                if let old = writer.object(ofType: FeedCategory.self, forPrimaryKey: id) { writer.delete(old) }
                let replacement = FeedCategory()
                replacement.id = id
                replacement.createdAt = Date(timeIntervalSinceReferenceDate: 200)
                replacement.title = "Replacement"
                writer.add(replacement)
            }
        }.value
        await gate.release()
        try await write.value
        realm.refresh()
        XCTAssertEqual(realm.object(ofType: FeedCategory.self, forPrimaryKey: id)?.title, "Replacement")
    }
}
