import Foundation
import XCTest
#if canImport(LakeOfFireContent)
@testable import LakeOfFireContent
#elseif canImport(EBookFingerprint)
@testable import EBookFingerprint
#else
@testable import EBookSnapshot
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ReaderEBookPackageSnapshotTests: XCTestCase {
    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("original.epub")
        try Data("original bytes".utf8).write(to: source)
        try body(source, parent)
    }

    private func snapshot(_ source: URL, _ parent: URL, limit: Int64 = 1_000_000) throws -> ReaderEBookPackageSnapshot {
        try .retainCoordinatedFile(at: source, maximumBytes: limit, temporaryParent: parent)
    }

    private func retainedDirectories(_ parent: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("manabi-epub-snapshot-") }
    }

    func testRetainsIndependentBytesAfterOriginalIsEdited() throws {
        try withFixture { source, parent in
            let owned = try snapshot(source, parent)
            try Data("modified source".utf8).write(to: source)
            XCTAssertEqual(try Data(contentsOf: owned.packageURL), Data("original bytes".utf8))
            try owned.validateObservation(owned.observationToken)
        }
    }

    func testRetainsBytesAfterOriginalIsRemoved() throws {
        try withFixture { source, parent in
            let owned = try snapshot(source, parent)
            try FileManager.default.removeItem(at: source)
            XCTAssertEqual(try Data(contentsOf: owned.packageURL), Data("original bytes".utf8))
            try owned.validateObservation(owned.observationToken)
        }
    }

    func testLastOwnerDeletesOnlyItsPrivateCopy() throws {
        try withFixture { source, parent in
            var owned: ReaderEBookPackageSnapshot? = try snapshot(source, parent)
            let url = try XCTUnwrap(owned).packageURL
            var secondOwner = owned
            owned = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            try XCTUnwrap(secondOwner).validateObservation(try XCTUnwrap(secondOwner).observationToken)
            secondOwner = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testIndependentSnapshotsCannotValidateEachOthersToken() throws {
        try withFixture { source, parent in
            let a = try snapshot(source, parent), b = try snapshot(source, parent)
            XCTAssertNotEqual(a.packageURL, b.packageURL)
            XCTAssertNotEqual(a.observationToken, b.observationToken)
            XCTAssertThrowsError(try a.validateObservation(b.observationToken))
            try a.validateObservation(a.observationToken)
            try b.validateObservation(b.observationToken)
        }
    }

    func testSnapshotIsNotAHardLinkAndIsReadOnly() throws {
        try withFixture { source, parent in
            let owned = try snapshot(source, parent)
            let a = try FileManager.default.attributesOfItem(atPath: source.path)
            let b = try FileManager.default.attributesOfItem(atPath: owned.packageURL.path)
            XCTAssertNotEqual(a[.systemFileNumber] as? NSNumber, b[.systemFileNumber] as? NSNumber)
            XCTAssertEqual((b[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        }
    }

    func testOversizedInputIsRejectedBeforeCreatingCopy() throws {
        try withFixture { source, parent in
            XCTAssertThrowsError(try snapshot(source, parent, limit: 1)) {
                XCTAssertEqual($0 as? ReaderEBookPackageSnapshotError, .limitExceeded)
            }
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
        }
    }

    func testExactBudgetIncludesEveryByte() throws {
        try withFixture { source, parent in
            let count = try Data(contentsOf: source).count
            let owned = try snapshot(source, parent, limit: Int64(count))
            XCTAssertEqual(try Data(contentsOf: owned.packageURL).count, count)
        }
    }

    func testNegativeBudgetIsRejected() throws {
        try withFixture { source, parent in
            XCTAssertThrowsError(try snapshot(source, parent, limit: -1))
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testNonFileURLIsRejectedWithoutSideEffects() throws {
        try withFixture { _, parent in
            XCTAssertThrowsError(try snapshot(URL(string: "https://example.invalid/book.epub")!, parent))
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testSymlinkCannotBeRetainedAsAnImmutableFile() throws {
        try withFixture { source, parent in
            let link = parent.appendingPathComponent("link.epub")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            XCTAssertThrowsError(try snapshot(link, parent))
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testDirectoryIsNotMistakenForCoordinatedSnapshotFile() throws {
        try withFixture { _, parent in
            XCTAssertThrowsError(try snapshot(parent, parent)) {
                XCTAssertEqual($0 as? ReaderEBookPackageSnapshotError, .unsupportedSource)
            }
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testFIFOIsRejectedWithoutWaitingForAWriter() throws {
        try withFixture { _, parent in
            let fifo = parent.appendingPathComponent("pipe")
            let status = fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
            XCTAssertEqual(status, 0)
            XCTAssertThrowsError(try snapshot(fifo, parent)) {
                XCTAssertEqual($0 as? ReaderEBookPackageSnapshotError, .unsupportedSource)
            }
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testCancellationAtEveryCopyBoundaryCleansUp() throws {
        try withFixture { source, parent in
            try Data(repeating: 7, count: 150_000).write(to: source)
            // Before open; each of three chunks; after copy; before publication.
            for boundary in 1...6 {
                var count = 0
                XCTAssertThrowsError(try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: source,
                    maximumBytes: 200_000, temporaryParent: parent, checkCancellation: {
                        count += 1
                        if count == boundary { throw CancellationError() }
                    })) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertTrue(try retainedDirectories(parent).isEmpty, "boundary \(boundary)")
                XCTAssertEqual(try Data(contentsOf: source).count, 150_000)
            }
        }
    }

    func testUnexpectedAccessorFailureCleansUp() throws {
        enum Failure: Error { case injected }
        try withFixture { source, parent in
            var count = 0
            XCTAssertThrowsError(try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: source,
                maximumBytes: 100, temporaryParent: parent, checkCancellation: {
                    count += 1
                    if count == 3 { throw Failure.injected }
                }))
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testInPlaceSourceEditDuringCopyIsNotPublished() throws {
        try withFixture { source, parent in
            try Data(repeating: 7, count: 150_000).write(to: source)
            var count = 0
            XCTAssertThrowsError(try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: source,
                maximumBytes: 200_000, temporaryParent: parent, checkCancellation: {
                    count += 1
                    if count == 3 {
                        let writer = try FileHandle(forWritingTo: source)
                        defer { try? writer.close() }
                        try writer.truncate(atOffset: 2)
                    }
                })) { XCTAssertEqual($0 as? ReaderEBookPackageSnapshotError, .sourceChanged) }
            XCTAssertTrue(try retainedDirectories(parent).isEmpty)
        }
    }

    func testRemovedPrivateCopyFailsObservation() throws {
        try withFixture { source, parent in
            let owned = try snapshot(source, parent)
            try FileManager.default.removeItem(at: owned.packageURL)
            XCTAssertThrowsError(try owned.validateObservation(owned.observationToken))
        }
    }

    func testReplacementPrivateCopyFailsEvenWithSameBytesAndToken() throws {
        try withFixture { source, parent in
            let owned = try snapshot(source, parent)
            let replacement = parent.appendingPathComponent("replacement")
            try Data("original bytes".utf8).write(to: replacement)
            try FileManager.default.removeItem(at: owned.packageURL)
            try FileManager.default.moveItem(at: replacement, to: owned.packageURL)
            XCTAssertThrowsError(try owned.validateObservation(owned.observationToken)) {
                XCTAssertEqual($0 as? ReaderEBookPackageSnapshotError, .unavailable)
            }
        }
    }

    func testPrivateCopySymlinkReplacementFailsObservation() throws {
        try withFixture { source, parent in
            let owned = try snapshot(source, parent)
            try FileManager.default.removeItem(at: owned.packageURL)
            try FileManager.default.createSymbolicLink(at: owned.packageURL, withDestinationURL: source)
            XCTAssertThrowsError(try owned.validateObservation(owned.observationToken))
        }
    }

    func testCaptureHonorsAlreadyCancelledTask() async throws {
        let task = Task { () throws -> ReaderEBookPackageSnapshot in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await .capture(at: URL(fileURLWithPath: "/missing/book.epub"))
        }
        do { _ = try await task.value; XCTFail("Cancellation must fail before filesystem access") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
