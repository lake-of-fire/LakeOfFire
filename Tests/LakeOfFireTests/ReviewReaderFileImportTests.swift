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
        return (incoming, library, drive)
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 1)
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 2)
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
}
