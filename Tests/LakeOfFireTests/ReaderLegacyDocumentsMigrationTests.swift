#if canImport(Darwin)
import Darwin
import Foundation
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderLegacyDocumentsMigrationTests: XCTestCase {
    func testMovesFileWithoutChangingItsBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = Data([0, 1, 255, 42])
        try fixture.write("book.epub", data)
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 1)
        XCTAssertEqual(report.recoveredItemCount, 0)
        XCTAssertEqual(try fixture.read("Documents/book.epub"), data)
        XCTAssertFalse(fixture.exists("book.epub"))
    }

    func testOccupiedFilePreservesBothVersions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data("legacy".utf8))
        try fixture.write("Documents/book.epub", Data("current".utf8))
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.recoveredItemCount, 1)
        XCTAssertEqual(try fixture.read("Documents/book.epub"), Data("current".utf8))
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub"), Data("legacy".utf8))
    }

    func testEqualBytesDoNotAuthorizeDiscardingASeparateOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([7]))
        try fixture.write("Documents/book.epub", Data([7]))
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.recoveredItemCount, 1)
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub"), Data([7]))
        XCTAssertEqual(try fixture.read("Documents/book.epub"), Data([7]))
    }

    func testOccupiedRecoveredNamesAreNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([3]))
        try fixture.write("Documents/book.epub", Data([1]))
        try fixture.write("Documents/book (Recovered 1).epub", Data([2]))
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try fixture.read("Documents/book.epub"), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub"), Data([2]))
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 2).epub"), Data([3]))
    }

    func testDirectoryCollisionDoesNotMergeTwoEPUBPackages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub/OPS/chapter.xhtml", Data("legacy chapter".utf8))
        try fixture.write("book.epub/.metadata", Data("legacy hidden".utf8))
        try fixture.write("Documents/book.epub/OPS/chapter.xhtml", Data("current chapter".utf8))
        try fixture.write("Documents/book.epub/current-only", Data([9]))
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 1)
        XCTAssertEqual(report.recoveredItemCount, 1)
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub/OPS/chapter.xhtml"), Data("legacy chapter".utf8))
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub/.metadata"), Data("legacy hidden".utf8))
        XCTAssertEqual(try fixture.read("Documents/book.epub/OPS/chapter.xhtml"), Data("current chapter".utf8))
        XCTAssertFalse(fixture.exists("Documents/book (Recovered 1).epub/current-only"))
        XCTAssertFalse(fixture.exists("book.epub"))
    }

    func testFolderCollisionKeepsTheEntireIncomingHierarchyTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Books/one.epub", Data([1]))
        try fixture.write("Books/Nested/two.epub", Data([2]))
        try fixture.write("Documents/Books/three.epub", Data([3]))
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try fixture.read("Documents/Books (Recovered 1)/one.epub"), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/Books (Recovered 1)/Nested/two.epub"), Data([2]))
        XCTAssertEqual(try fixture.read("Documents/Books/three.epub"), Data([3]))
    }

    func testUnoccupiedDirectoryRetainsHiddenDescendantsAndEmptyDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Books/.private/note", Data([8]))
        try fixture.directory("Books/empty")
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try fixture.read("Documents/Books/.private/note"), Data([8]))
        XCTAssertTrue(fixture.exists("Documents/Books/empty"))
        XCTAssertFalse(fixture.exists("Books"))
    }

    func testDirectoryIntoOccupiedFilePreservesBothTypes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Books/one", Data([1]))
        try fixture.write("Documents/Books", Data([2]))
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try fixture.read("Documents/Books"), Data([2]))
        XCTAssertEqual(try fixture.read("Documents/Books (Recovered 1)/one"), Data([1]))
    }

    func testFileIntoOccupiedDirectoryPreservesBothTypes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Book", Data([1]))
        try fixture.write("Documents/Book/inside", Data([2]))
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try fixture.read("Documents/Book (Recovered 1)"), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/Book/inside"), Data([2]))
    }

    func testHiddenContainerMetadataIsNotMigrated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".container-metadata", Data([1]))
        try fixture.write(".private/metadata", Data([2]))
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 0)
        XCTAssertEqual(try fixture.read(".container-metadata"), Data([1]))
        XCTAssertEqual(try fixture.read(".private/metadata"), Data([2]))
    }

    func testEmptyContainerCreatesDestinationWithoutReportingAMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 0)
        XCTAssertEqual(report.recoveredItemCount, 0)
        XCTAssertTrue(fixture.exists("Documents"))
    }

    func testDocumentsIsNeverMovedIntoItself() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Documents/book.epub", Data([1]))
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 0)
        XCTAssertEqual(try fixture.read("Documents/book.epub"), Data([1]))
        XCTAssertFalse(fixture.exists("Documents/Documents"))
    }

    func testSecondRunAfterStorageCommitIsANoOp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        try fixture.write("Documents/book.epub", Data([2]))
        let actor = ReaderLegacyDocumentsMigration()
        _ = try await actor.migrate(containerURL: fixture.root)
        let report = try await actor.migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 0)
        XCTAssertFalse(fixture.exists("Documents/book (Recovered 2).epub"))
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub"), Data([1]))
    }

    func testRetryOfAPartiallyMigratedContainerDoesNotDuplicateCommittedMoves() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Documents/already-moved.epub", Data([1]))
        try fixture.write("remaining.epub", Data([2]))
        let report = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(report.movedItemCount, 1)
        XCTAssertEqual(report.recoveredItemCount, 0)
        XCTAssertEqual(try fixture.read("Documents/already-moved.epub"), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/remaining.epub"), Data([2]))
    }

    func testQueuedCallsOnOneOwnerDoNotDuplicateItems() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let owner = ReaderLegacyDocumentsMigration()
        let root = fixture.root
        async let first = owner.migrate(containerURL: root)
        async let second = owner.migrate(containerURL: root)
        let reports = try await [first, second]
        XCTAssertEqual(reports.map(\.movedItemCount).sorted(), [0, 1])
        XCTAssertFalse(fixture.exists("Documents/book (Recovered 1).epub"))
    }

    func testPreCancelledTaskDoesNotEvenCreateDocuments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let root = fixture.root
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: root)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try fixture.read("book.epub"), Data([1]))
        XCTAssertFalse(fixture.exists("Documents"))
    }

    func testDocumentsFileIsNotOverwrittenOrDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Documents", Data([1]))
        try fixture.write("book.epub", Data([2]))
        do {
            _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
            XCTFail("Expected a destination failure")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .invalidDestination) }
        XCTAssertEqual(try fixture.read("Documents"), Data([1]))
        XCTAssertEqual(try fixture.read("book.epub"), Data([2]))
    }

    func testDocumentsSymlinkCannotRedirectWritesOutsideContainer() async throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        defer { fixture.remove(); outside.remove() }
        try fixture.write("book.epub", Data([1]))
        try FileManager.default.createSymbolicLink(at: fixture.url("Documents"), withDestinationURL: outside.root)
        do {
            _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
            XCTFail("Expected symlink destination rejection")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .invalidDestination) }
        XCTAssertEqual(try fixture.read("book.epub"), Data([1]))
        XCTAssertFalse(outside.exists("book.epub"))
    }

    func testOccupiedDanglingLinkRemainsOccupied() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Documents")
        try fixture.write("book.epub", Data([1]))
        try FileManager.default.createSymbolicLink(atPath: fixture.url("Documents/book.epub").path, withDestinationPath: "missing")
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("Documents/book.epub").path), "missing")
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub"), Data([1]))
    }

    func testTopLevelSymbolicLinkIsRejectedWithoutTouchingItsTarget() async throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("target", Data([7]))
        try FileManager.default.createSymbolicLink(at: fixture.url("alias"), withDestinationURL: outside.url("target"))
        do {
            _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
            XCTFail("Expected top-level link rejection")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .unsupportedItem) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("alias").path), outside.url("target").path)
        XCTAssertEqual(try outside.read("target"), Data([7]))
    }

    func testNestedSymbolicLinkDoesNotCauseRecursiveTraversal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Books")
        try FileManager.default.createSymbolicLink(atPath: fixture.url("Books/loop").path, withDestinationPath: ".")
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("Documents/Books/loop").path), ".")
    }

    func testUnsupportedSpecialFileStaysInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(mkfifo(fixture.url("pipe").path, 0o600), 0)
        do {
            _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
            XCTFail("Expected special file rejection")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .unsupportedItem) }
        XCTAssertTrue(fixture.exists("pipe"))
    }

    func testFileIdentityAndMetadataSurviveRelocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: fixture.url("book.epub").path)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.url("book.epub").path)
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.url("Documents/book.epub").path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))
        XCTAssertEqual(after[.modificationDate] as? Date, date)
    }

    func testUnicodeFilenameAndPayloadArePreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "日本語・e\u{301} 📚.epub"
        let text = Data("<ruby>漢字<rt>かんじ</rt></ruby>".utf8)
        try fixture.write(name, text)
        try fixture.write("Documents/" + name, Data([0]))
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        let recovered = try ReaderLegacyDocumentsMigration.recoveredName(name, ordinal: 1)
        XCTAssertEqual(try fixture.read("Documents/" + recovered), text)
        XCTAssertEqual(try fixture.read("Documents/" + name), Data([0]))
    }

    func testLongRecoveredNameStaysWithinByteLimitAndRetainsExtension() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = String(repeating: "a", count: 250) + ".epub"
        try fixture.write(name, Data([1]))
        try fixture.write("Documents/" + name, Data([2]))
        _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
        let recovered = try ReaderLegacyDocumentsMigration.recoveredName(name, ordinal: 1)
        XCTAssertLessThanOrEqual(recovered.utf8.count, 255)
        XCTAssertTrue(recovered.hasSuffix(" (Recovered 1).epub"))
        XCTAssertEqual(try fixture.read("Documents/" + recovered), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/" + name), Data([2]))
    }

    func testRecoveryNameDoesNotSplitUnicodeCharacters() async throws {
        let name = String(repeating: "日", count: 80) + ".epub"
        let recovered = try ReaderLegacyDocumentsMigration.recoveredName(name, ordinal: 10_000)
        XCTAssertLessThanOrEqual(recovered.utf8.count, 255)
        XCTAssertTrue(recovered.hasSuffix(" (Recovered 10000).epub"))
        XCTAssertFalse(recovered.contains("�"))
        XCTAssertThrowsError(try ReaderLegacyDocumentsMigration.recoveredName(name, ordinal: 0))
        XCTAssertThrowsError(try ReaderLegacyDocumentsMigration.recoveredName(name, ordinal: 10_001))
    }

    func testInvalidContainerDoesNotCreateLocalPaths() async {
        for url in [URL(string: "https://example.invalid/book")!, URL(fileURLWithPath: "/")] {
            do {
                _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: url)
                XCTFail("Expected invalid container")
            } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .invalidContainer) }
        }
    }

    func testNoFallbackCopyOrDeletionForUnrepresentableRecoveryName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "a." + String(repeating: "x", count: 250)
        try fixture.write(name, Data([1]))
        try fixture.write("Documents/" + name, Data([2]))
        do {
            _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root)
            XCTFail("Expected exhausted recovery name")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .recoveryNameExhausted) }
        XCTAssertEqual(try fixture.read(name), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/" + name), Data([2]))
    }

    func testStaleAdmissionBeforeActorEntryCreatesNoDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        do {
            _ = try await ReaderLegacyDocumentsMigration().migrate(containerURL: fixture.root, validateAdmission: { false })
            XCTFail("Expected expired admission")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .admissionExpired) }
        XCTAssertTrue(fixture.exists("book.epub"))
        XCTAssertFalse(fixture.exists("Documents"))
    }

    func testAccountChangeImmediatelyBeforeRenameBalancesNotificationAndPreservesSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let state = MoveState()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.isCurrent = { state.current }
        environment.moveNotification = { source, destination, completed in
            state.notifications.append((source, destination, completed))
            if !completed { state.current = false }
        }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("Expected expired admission")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .admissionExpired) }
        XCTAssertEqual(try fixture.read("book.epub"), Data([1]))
        XCTAssertFalse(fixture.exists("Documents/book.epub"))
        XCTAssertEqual(state.notifications.count, 2)
        XCTAssertEqual(state.notifications.last?.1, fixture.url("book.epub"))
        XCTAssertEqual(state.notifications.last?.2, true)
    }

    func testAccountChangeAfterFirstCommitPreservesEarlierMoveAndRemainingOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("a.epub", Data([1]))
        try fixture.write("b.epub", Data([2]))
        let state = MoveState()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.isCurrent = { state.current }
        environment.moveNotification = { _, _, completed in if completed { state.current = false } }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("Expected expired admission")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .admissionExpired) }
        XCTAssertEqual(try fixture.read("Documents/a.epub"), Data([1]))
        XCTAssertEqual(try fixture.read("b.epub"), Data([2]))
    }

    func testDestinationReplacementDuringPresenterCallbackRejectsDescriptorCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        try fixture.write("Documents/existing.epub", Data([2]))
        let root = fixture.root
        let source = fixture.url("book.epub")
        let destination = fixture.url("Documents")
        let displaced = fixture.url("DisplacedDocuments")
        let state = MoveState()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.rename = { _, _, _, _ in
            state.renameCount += 1
            errno = EIO
            return -1
        }
        environment.moveNotification = { from, to, completed in
            state.notifications.append((from, to, completed))
            if !completed {
                do {
                    try FileManager.default.moveItem(at: destination, to: displaced)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                } catch { XCTFail("Could not replace destination during presenter callback: \(error)") }
            }
        }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: root)
            XCTFail("Replaced destination must reject the announced move")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .invalidDestination) }
        XCTAssertEqual(state.renameCount, 0)
        XCTAssertEqual(state.notifications.count, 2)
        XCTAssertEqual(state.notifications.last?.1, source)
        XCTAssertEqual(state.notifications.last?.2, true)
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
        XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("existing.epub")), Data([2]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("book.epub").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("book.epub").path))
    }

    func testSourceReplacementDuringPresenterCallbackPreservesOriginalAndSuccessor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let root = fixture.root
        let source = fixture.url("book.epub")
        let savedOriginal = fixture.url(".saved-original.epub")
        let target = fixture.url("Documents/book.epub")
        let state = MoveState()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.rename = { _, _, _, _ in
            state.renameCount += 1
            errno = EIO
            return -1
        }
        environment.moveNotification = { from, to, completed in
            state.notifications.append((from, to, completed))
            if !completed {
                do {
                    try FileManager.default.moveItem(at: source, to: savedOriginal)
                    try Data([3]).write(to: source)
                } catch { XCTFail("Could not replace source during presenter callback: \(error)") }
            }
        }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: root)
            XCTFail("Replaced source must reject the announced move")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .sourceChanged) }
        XCTAssertEqual(state.renameCount, 0)
        XCTAssertEqual(state.notifications.count, 2)
        XCTAssertEqual(state.notifications.last?.1, source)
        XCTAssertEqual(state.notifications.last?.2, true)
        XCTAssertEqual(try Data(contentsOf: savedOriginal), Data([1]))
        XCTAssertEqual(try Data(contentsOf: source), Data([3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testFailedRenameBalancesPresenterNotificationAndRetainsOriginalErrno() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let state = MoveState()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.rename = { _, _, _, _ in errno = EXDEV; return -1 }
        environment.moveNotification = { source, destination, completed in
            state.notifications.append((source, destination, completed))
            if completed { errno = EIO }
        }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("Expected rename failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EXDEV))
        }
        XCTAssertEqual(state.notifications.count, 2)
        XCTAssertEqual(state.notifications.last?.1, fixture.url("book.epub"))
        XCTAssertEqual(try fixture.read("book.epub"), Data([1]))
        XCTAssertFalse(fixture.exists("Documents/book.epub"))
    }

    func testExclusiveRenameCollisionBalancesNotificationAndRetriesRecoveredName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let state = MoveState()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        let nativeRename = environment.rename
        environment.rename = { source, name, destination, target in
            if state.notifications.count == 1 { errno = EEXIST; return -1 }
            return nativeRename(source, name, destination, target)
        }
        environment.moveNotification = { source, destination, completed in
            state.notifications.append((source, destination, completed))
        }
        let report = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
        XCTAssertEqual(report.recoveredItemCount, 1)
        XCTAssertEqual(state.notifications.count, 4)
        XCTAssertEqual(state.notifications[1].1, fixture.url("book.epub"))
        XCTAssertEqual(try fixture.read("Documents/book (Recovered 1).epub"), Data([1]))
    }

    func testEvictedDestinationContentsDoNotAdmitPayloadOrBlockLegacyMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Documents/current.epub", Data([2]))
        try fixture.write("legacy.epub", Data([1]))
        let root = fixture.root
        let destination = fixture.url("Documents")
        let existing = fixture.url("Documents/current.epub")
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.inventory = { _ in [existing] }
        environment.requirePayload = { url in
            if url.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path) {
                throw ReaderLegacyDocumentsMigration.Failure.payloadUnavailable
            }
        }
        let report = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: root)
        XCTAssertEqual(report.movedItemCount, 1)
        XCTAssertEqual(try fixture.read("Documents/legacy.epub"), Data([1]))
        XCTAssertEqual(try fixture.read("Documents/current.epub"), Data([2]))
    }

    func testCloudOnlyLogicalItemCannotCompleteWithoutPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let logicalURL = fixture.url("evicted.epub")
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.inventory = { _ in [logicalURL] }
        environment.requirePayload = { url in
            if url == logicalURL { throw ReaderLegacyDocumentsMigration.Failure.payloadUnavailable }
        }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("Cloud-only payload must remain retryable")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .payloadUnavailable) }
    }

    func testCloudOnlyDescendantPreventsMovingPartiallyMaterializedPackage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub/local", Data([1]))
        let unavailable = fixture.url("book.epub/remote")
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.inventory = { _ in [unavailable] }
        environment.requirePayload = { if $0 == unavailable { throw ReaderLegacyDocumentsMigration.Failure.payloadUnavailable } }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("Incomplete package must remain retryable")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .payloadUnavailable) }
        XCTAssertEqual(try fixture.read("book.epub/local"), Data([1]))
        XCTAssertFalse(fixture.exists("Documents/book.epub"))
    }

    func testEmptyProviderInventoryDoesNotHideUnavailableLocalUserItem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("pending.epub", Data([1]))
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.inventory = { _ in [] }
        environment.requirePayload = { _ in throw ReaderLegacyDocumentsMigration.Failure.payloadUnavailable }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("An empty provider query cannot complete pending local work")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .payloadUnavailable) }
        XCTAssertEqual(try fixture.read("pending.epub"), Data([1]))
    }

    func testInventoryFailurePreservesOriginalForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.inventory = { _ in throw ReaderLegacyDocumentsMigration.Failure.inventoryUnavailable }
        do {
            _ = try await ReaderLegacyDocumentsMigration(environment: environment).migrate(containerURL: fixture.root)
            XCTFail("Expected retryable inventory failure")
        } catch { XCTAssertEqual(error as? ReaderLegacyDocumentsMigration.Failure, .inventoryUnavailable) }
        XCTAssertEqual(try fixture.read("book.epub"), Data([1]))
    }

    func testSuspendedOldInventoryCannotOverwriteAConcurrentCommittedMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("book.epub", Data([1]))
        let root = fixture.root
        let logical = fixture.url("book.epub")
        let gate = InventoryGate()
        var environment = ReaderLegacyDocumentsMigration.Environment()
        environment.inventory = { _ in await gate.snapshot() }
        let migration = ReaderLegacyDocumentsMigration(environment: environment)
        let oldAttempt = Task { try await migration.migrate(containerURL: root) }
        let deadline = Date().addingTimeInterval(2)
        while !(await gate.isSuspended), Date() < deadline { await Task.yield() }
        guard await gate.isSuspended else {
            oldAttempt.cancel()
            await gate.release([])
            _ = try? await oldAttempt.value
            XCTFail("First inventory did not suspend")
            return
        }
        let report = try await migration.migrate(containerURL: root)
        XCTAssertEqual(report.movedItemCount, 1)
        await gate.release([logical])
        do {
            _ = try await oldAttempt.value
            XCTFail("An old snapshot must remain retryable")
        } catch { /* The committed logical source no longer has payload. */ }
        XCTAssertEqual(try fixture.read("Documents/book.epub"), Data([1]))
        XCTAssertFalse(fixture.exists("book.epub"))
        XCTAssertFalse(fixture.exists("Documents/book (Recovered 1).epub"))
    }

    private actor InventoryGate {
        private var calls = 0
        private var continuation: CheckedContinuation<[URL], Never>?
        var isSuspended: Bool { continuation != nil }
        func snapshot() async -> [URL] {
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { continuation = $0 }
            }
            return []
        }
        func release(_ urls: [URL]) {
            continuation?.resume(returning: urls)
            continuation = nil
        }
    }

    func testLogicalInventoryCollapsesPackagesAndExcludesMetadataAndOtherContainers() throws {
        let root = URL(fileURLWithPath: "/container")
        let children = try ReaderLegacyDocumentsMigration.logicalChildren([
            root.appendingPathComponent("book.epub/chapter"),
            root.appendingPathComponent("book.epub/remote"),
            root.appendingPathComponent(".metadata/item"),
            URL(fileURLWithPath: "/container-other/book.epub")
        ], root: root)
        XCTAssertEqual(children, [root.appendingPathComponent("book.epub")])
    }

    func testLogicalCloudDescendantThroughExistingRootAliasIsNotIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-alias-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: alias) }
        let logical = alias.appendingPathComponent("cloud-only.epub/OPS/chapter.xhtml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logical.path))
        let children = try ReaderLegacyDocumentsMigration.logicalChildren([logical], root: fixture.root)
        XCTAssertEqual(children, [fixture.url("cloud-only.epub")])
        let throughAlias = try ReaderLegacyDocumentsMigration.logicalChildren([logical], root: alias)
        XCTAssertEqual(throughAlias, [fixture.url("cloud-only.epub")])
    }

    // Mutations occur only in the migration actor's synchronous callbacks;
    // XCTest reads the state after joining that actor operation.
    private final class MoveState: @unchecked Sendable {
        var current = true
        var renameCount = 0
        var notifications: [(URL, URL, Bool)] = []
    }

    private final class Fixture {
        let root: URL
        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-documents-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let canonicalPath = directory.path.withCString({ realpath($0, nil) }) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { free(canonicalPath) }
            root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
        }
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
        func read(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
        func directory(_ path: String) throws { try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true) }
        func write(_ path: String, _ data: Data) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url(path))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
