import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

@MainActor
private final class ReaderContentAppearanceFixture {
    let realm: Realm
    let file: ContentFile
    let bookmark: Bookmark
    var events: [String] = []

    init() throws {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ReaderContentAppearance-\(UUID().uuidString)",
            objectTypes: [Bookmark.self, ContentFile.self]
        )
        let realm = try Realm(configuration: configuration)
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/appearance.epub")!
        file.updateCompoundKey()
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/appearance")!
        bookmark.updateCompoundKey()
        try realm.write {
            realm.add(file)
            realm.add(bookmark)
        }
        self.realm = realm
        self.file = file
        self.bookmark = bookmark
    }

    func deleteFile() throws {
        try realm.write { realm.delete(file) }
    }
}

@MainActor
final class ReaderContentAppearanceTests: XCTestCase {
    func testRowDeletedBeforeQueuedAppearanceSkipsCallbackAndFileStatus() async throws {
        let fixture = try ReaderContentAppearanceFixture()
        let task = Task { @MainActor in
            await performReaderContentAppearance(
                fixture.file,
                onContentAppear: { _ in fixture.events.append("appearance") }
            ) { _ in
                fixture.events.append("status")
            }
        }
        // The current MainActor turn retains control until the await below.
        try fixture.deleteFile()
        XCTAssertTrue(fixture.file.isInvalidated)

        await task.value

        XCTAssertEqual(fixture.events, [])
    }

    func testCancelledQueuedAppearanceSkipsCallbackAndFileStatus() async throws {
        let fixture = try ReaderContentAppearanceFixture()
        let task = Task { @MainActor in
            await performReaderContentAppearance(
                fixture.file,
                onContentAppear: { _ in fixture.events.append("appearance") }
            ) { _ in
                fixture.events.append("status")
            }
        }
        task.cancel()

        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(fixture.file.isInvalidated)
        XCTAssertEqual(fixture.events, [])
    }

    func testCurrentFilePublishesAppearanceBeforeStatusForTheSameRow() async throws {
        let fixture = try ReaderContentAppearanceFixture()
        let key = fixture.file.compoundKey

        await performReaderContentAppearance(
            fixture.file,
            onContentAppear: { content in
                XCTAssertTrue(content === fixture.file)
                XCTAssertEqual(content.compoundKey, key)
                fixture.events.append("appearance")
            }
        ) { file in
            XCTAssertTrue(file === fixture.file)
            XCTAssertEqual(file.compoundKey, key)
            fixture.events.append("status")
        }

        XCTAssertEqual(fixture.events, ["appearance", "status"])
    }

    func testCurrentBookmarkPublishesAppearanceWithoutFileStatus() async throws {
        let fixture = try ReaderContentAppearanceFixture()

        await performReaderContentAppearance(
            fixture.bookmark,
            onContentAppear: { content in
                XCTAssertTrue(content === fixture.bookmark)
                fixture.events.append("appearance")
            }
        ) { _ in
            fixture.events.append("status")
        }

        XCTAssertEqual(fixture.events, ["appearance"])
    }

    func testCallbackDeletionSuppressesFollowingFileStatusWork() async throws {
        let fixture = try ReaderContentAppearanceFixture()

        await performReaderContentAppearance(
            fixture.file,
            onContentAppear: { _ in
                fixture.events.append("appearance")
                do {
                    try fixture.deleteFile()
                } catch {
                    XCTFail("Fixture deletion failed: \(error)")
                }
            }
        ) { _ in
            fixture.events.append("status")
        }

        XCTAssertTrue(fixture.file.isInvalidated)
        XCTAssertEqual(fixture.events, ["appearance"])
    }

    func testCallbackCancellationSuppressesFollowingFileStatusWork() async throws {
        let fixture = try ReaderContentAppearanceFixture()
        let task = Task { @MainActor in
            await performReaderContentAppearance(
                fixture.file,
                onContentAppear: { _ in
                    fixture.events.append("appearance")
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            ) { _ in
                fixture.events.append("status")
            }
        }

        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(fixture.events, ["appearance"])
    }

    func testCurrentFileWithoutAppearanceCallbackStillRefreshesStatus() async throws {
        let fixture = try ReaderContentAppearanceFixture()

        await performReaderContentAppearance(
            fixture.file,
            onContentAppear: nil
        ) { file in
            XCTAssertTrue(file === fixture.file)
            fixture.events.append("status")
        }

        XCTAssertEqual(fixture.events, ["status"])
    }
}
