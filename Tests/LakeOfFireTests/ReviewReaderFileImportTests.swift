import Foundation
import XCTest
import SwiftCloudDrive
@testable import LakeOfFireContent

@MainActor
final class ReviewReaderFileImportTests: XCTestCase {
    private func fixture() async throws -> (URL, URL, CloudDrive) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-import-" + UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let drive = try await CloudDrive(storage: .localDirectory(rootURL: library))
        return (incoming, drive.rootDirectory, drive)
    }
    private func install(_ url: URL, drive: CloudDrive) async throws -> URL {
        let path = try await ReaderFileImportStorage.install(fileURL: url, targetDirectory: .root, drive: drive)
        return try path.fileURL(forRoot: drive.rootDirectory)
    }
    func testIdenticalFileAtDifferentURLReusesExistingDestination() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.txt")
        let target = library.appendingPathComponent("book.txt")
        let bytes = Data("same document".utf8)
        try bytes.write(to: source)
        try bytes.write(to: target)
        let result = try await install(source, drive: drive)
        XCTAssertEqual(result.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }.count,
            1
        )
    }
    func testRepeatedCollisionImportReusesThePreviouslyRenamedFile() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.txt")
        let original = library.appendingPathComponent("book.txt")
        try Data("original user file".utf8).write(to: original)
        try Data("different imported file".utf8).write(to: source)
        let first = try await install(source, drive: drive)
        let second = try await install(source, drive: drive)
        XCTAssertEqual(first.standardizedFileURL, second.standardizedFileURL)
        XCTAssertNotEqual(first.lastPathComponent, original.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: original), Data("original user file".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("different imported file".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }.count,
            2
        )
    }
    func testOccupiedCollisionNameIsNotOverwritten() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.txt")
        let original = library.appendingPathComponent("book.txt")
        try Data("original".utf8).write(to: original)
        try Data("imported".utf8).write(to: source)
        let collided = try await install(source, drive: drive)
        try Data("user changed renamed file".utf8).write(to: collided)
        let next = try await install(source, drive: drive)
        XCTAssertNotEqual(next.standardizedFileURL, collided.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: collided), Data("user changed renamed file".utf8))
        XCTAssertEqual(try Data(contentsOf: next), Data("imported".utf8))
    }
    func testNewFileAndSameURLControls() async throws {
        let (incoming, _, drive) = try await fixture()
        let source = incoming.appendingPathComponent("fresh.txt")
        let bytes = Data("fresh".utf8)
        try bytes.write(to: source)
        let result = try await install(source, drive: drive)
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        let again = try await install(result, drive: drive)
        XCTAssertEqual(again.standardizedFileURL, result.standardizedFileURL)
    }
    func testMissingSourceDoesNotOverwriteAnExistingFile() async throws {
        let (incoming, library, drive) = try await fixture()
        let target = library.appendingPathComponent("missing.txt")
        try Data("keep".utf8).write(to: target)
        do {
            _ = try await install(incoming.appendingPathComponent("missing.txt"), drive: drive)
            XCTFail("A real I/O error must reach the caller")
        } catch {
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        }
    }

    func testIdenticalDirectoryAtDifferentURLReusesExistingDestination() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.epub", isDirectory: true)
        let target = library.appendingPathComponent("book.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let mimetype = Data("application/epub+zip".utf8)
        let chapter = Data("<p>same</p>".utf8)
        try mimetype.write(to: source.appendingPathComponent("mimetype"))
        try mimetype.write(to: target.appendingPathComponent("mimetype"))
        try chapter.write(to: source.appendingPathComponent("chapter.xhtml"))
        try chapter.write(to: target.appendingPathComponent("chapter.xhtml"))

        let result = try await install(source, drive: drive)

        XCTAssertEqual(result.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: library,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { $0.lastPathComponent.hasPrefix("book") }.count,
            1
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("chapter.xhtml")),
            chapter
        )
    }

    func testRepeatedDirectoryCollisionReusesPreviouslyRenamedDirectory() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.epub", isDirectory: true)
        let original = library.appendingPathComponent("book.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("incoming".utf8).write(to: source.appendingPathComponent("chapter.xhtml"))
        try Data("original".utf8).write(to: original.appendingPathComponent("chapter.xhtml"))

        let first = try await install(source, drive: drive)
        let second = try await install(source, drive: drive)

        XCTAssertEqual(first.standardizedFileURL, second.standardizedFileURL)
        XCTAssertNotEqual(first.standardizedFileURL, original.standardizedFileURL)
        XCTAssertEqual(
            try Data(contentsOf: original.appendingPathComponent("chapter.xhtml")),
            Data("original".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: second.appendingPathComponent("chapter.xhtml")),
            Data("incoming".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: library,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { $0.lastPathComponent.hasPrefix("book") }.count,
            2
        )
    }

    func testFileAndDirectoryWithSameNameAreNeverTreatedAsIdentical() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.epub", isDirectory: true)
        let occupiedFile = library.appendingPathComponent("book.epub")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("directory payload".utf8).write(
            to: source.appendingPathComponent("chapter.xhtml")
        )
        try Data("ordinary file".utf8).write(to: occupiedFile)

        let result = try await install(source, drive: drive)

        XCTAssertNotEqual(result.standardizedFileURL, occupiedFile.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: occupiedFile), Data("ordinary file".utf8))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testFileSourceDoesNotReuseOccupiedDirectory() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("notes.txt")
        let occupiedDirectory = library.appendingPathComponent(
            "notes.txt",
            isDirectory: true
        )
        try Data("file payload".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: occupiedDirectory,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(
            to: occupiedDirectory.appendingPathComponent("nested.txt")
        )

        let result = try await install(source, drive: drive)

        XCTAssertNotEqual(result.standardizedFileURL, occupiedDirectory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: result), Data("file payload".utf8))
        XCTAssertEqual(
            try Data(contentsOf: occupiedDirectory.appendingPathComponent("nested.txt")),
            Data("keep".utf8)
        )
    }

    func testSymlinkSourceIsRejectedInsteadOfImportingExternalAuthority() async throws {
        let (incoming, library, drive) = try await fixture()
        let outside = incoming.appendingPathComponent("outside.txt")
        let sourceLink = incoming.appendingPathComponent("book.txt")
        try Data("outside payload".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: sourceLink,
            withDestinationURL: outside
        )
        let entriesBefore = try Set(FileManager.default.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: nil
        ))

        do {
            _ = try await install(sourceLink, drive: drive)
            XCTFail("A symlink source must not be installed into the managed library")
        } catch {
        }

        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(
                at: library,
                includingPropertiesForKeys: nil
            )),
            entriesBefore
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside payload".utf8))
    }

    func testExistingSymlinkDestinationIsNotReusedEvenWhenTargetBytesMatch() async throws {
        let (incoming, library, drive) = try await fixture()
        let source = incoming.appendingPathComponent("book.txt")
        let outside = incoming.appendingPathComponent("outside.txt")
        let occupiedLink = library.appendingPathComponent("book.txt")
        let payload = Data("same bytes".utf8)
        try payload.write(to: source)
        try payload.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: occupiedLink,
            withDestinationURL: outside
        )

        let result = try await install(source, drive: drive)

        XCTAssertNotEqual(result.standardizedFileURL, occupiedLink.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(try Data(contentsOf: outside), payload)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: occupiedLink.path
            ),
            outside.path
        )
    }
}
