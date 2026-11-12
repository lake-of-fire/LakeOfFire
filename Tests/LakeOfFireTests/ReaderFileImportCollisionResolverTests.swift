import Foundation
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderFileImportCollisionResolverTests: XCTestCase {
    private typealias Resolver = ReaderFileImportCollisionResolver

    @MainActor
    private final class Files {
        let root: URL
        let source: URL
        let destination: URL
        var copies = [String]()
        var names = [Int]()
        var inspections = [String]()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            source = root.appendingPathComponent("source/book.epub")
            destination = root.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: source)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: destination.appendingPathComponent(name))
        }
        func read(_ name: String) throws -> String {
            String(decoding: try Data(contentsOf: destination.appendingPathComponent(name)), as: UTF8.self)
        }
        func inspect(_ name: String) throws -> Resolver.Destination {
            inspections.append(name)
            let url = destination.appendingPathComponent(name)
            var directory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return .missing }
            if directory.boolValue { return .different }
            return try Data(contentsOf: source) == Data(contentsOf: url) ? .identical : .different
        }
        func copy(_ name: String) throws {
            copies.append(name)
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(name))
        }
        func name(_ ordinal: Int) -> String {
            names.append(ordinal)
            return "book (HASH" + (ordinal == 1 ? "" : "-\(ordinal)") + ").epub"
        }
        func install() async throws -> String {
            try await Resolver.install(originalName: "book.epub", collisionName: name, inspect: inspect, copyExclusively: copy)
        }
    }

    func testFreshImportCopiesOriginalNameWithoutComputingCollisionTag() async throws {
        let f = try Files()
        let result = try await f.install()
        XCTAssertEqual(result, "book.epub")
        XCTAssertEqual(f.copies, [result])
        XCTAssertTrue(f.names.isEmpty)
        XCTAssertEqual(try f.read(result), "new")
    }

    func testDuplicateBytesReuseOriginalWithoutCopy() async throws {
        let f = try Files()
        try f.write("book.epub", "new")
        let result = try await f.install()
        XCTAssertEqual(result, "book.epub")
        XCTAssertTrue(f.copies.isEmpty)
        XCTAssertTrue(f.names.isEmpty)
    }

    func testDifferentBytesPreserveOriginalAndChooseFirstSuffix() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        let result = try await f.install()
        XCTAssertEqual(result, "book (HASH).epub")
        XCTAssertEqual(try f.read("book.epub"), "old")
        XCTAssertEqual(try f.read(result), "new")
    }

    func testOccupiedHashSuffixAdvancesWithoutOverwritingEitherItem() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        try f.write("book (HASH).epub", "unrelated")
        let result = try await f.install()
        XCTAssertEqual(result, "book (HASH-2).epub")
        XCTAssertEqual(f.names, [1, 2])
        XCTAssertEqual(try f.read("book.epub"), "old")
        XCTAssertEqual(try f.read("book (HASH).epub"), "unrelated")
    }

    func testIdenticalHashedItemIsReusedWithoutAnExtraCopy() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        try f.write("book (HASH).epub", "new")
        let result = try await f.install()
        XCTAssertEqual(result, "book (HASH).epub")
        XCTAssertTrue(f.copies.isEmpty)
    }

    func testSeveralSuffixCollisionsAreAllInspected() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        for number in 1...12 { try f.write(f.name(number), "existing-\(number)") }
        f.names.removeAll()
        let result = try await f.install()
        XCTAssertEqual(result, "book (HASH-13).epub")
        XCTAssertEqual(f.names, Array(1...13))
        XCTAssertEqual(f.copies, [result])
    }

    func testDirectoryAtFileDestinationIsAnOccupiedName() async throws {
        let f = try Files()
        try FileManager.default.createDirectory(at: f.destination.appendingPathComponent("book.epub"), withIntermediateDirectories: true)
        let result = try await f.install()
        XCTAssertEqual(result, "book (HASH).epub")
    }

    func testConcurrentIdenticalWinnerIsReusedAfterCopyRefusesReplacement() async throws {
        let f = try Files()
        let result = try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: f.inspect) { name in
            try f.write(name, "new")
            try f.copy(name)
        }
        XCTAssertEqual(result, "book.epub")
        XCTAssertEqual(f.inspections, ["book.epub", "book.epub"])
        XCTAssertTrue(f.names.isEmpty)
    }

    func testConcurrentDifferentWinnerGetsANewName() async throws {
        let f = try Files()
        var first = true
        let result = try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: f.inspect) { name in
            if first { first = false; try f.write(name, "winner") }
            try f.copy(name)
        }
        XCTAssertEqual(result, "book (HASH).epub")
        XCTAssertEqual(try f.read("book.epub"), "winner")
    }

    func testConcurrentCollisionAtSuffixRetriesAgain() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        var first = true
        let result = try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: f.inspect) { name in
            if first { first = false; try f.write(name, "winner") }
            try f.copy(name)
        }
        XCTAssertEqual(result, "book (HASH-2).epub")
        XCTAssertEqual(try f.read("book (HASH).epub"), "winner")
    }

    func testNonCollisionCopyFailurePropagatesWithoutRetry() async throws {
        let f = try Files()
        do {
            _ = try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: f.inspect) { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        XCTAssertTrue(f.names.isEmpty)
    }

    func testSameNumericCodeInUnrelatedErrorDomainIsNotRetried() async throws {
        let f = try Files()
        do {
            _ = try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: f.inspect) { _ in
                throw NSError(domain: "test.provider", code: CocoaError.fileWriteFileExists.rawValue)
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as NSError).domain, "test.provider") }
        XCTAssertTrue(f.names.isEmpty)
    }

    func testInspectionFailureNeverCopiesOrRenames() async throws {
        let f = try Files()
        do {
            _ = try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: { _ in
                throw CocoaError(.fileReadNoPermission)
            }, copyExclusively: f.copy)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue) }
        XCTAssertTrue(f.copies.isEmpty)
        XCTAssertTrue(f.names.isEmpty)
    }

    func testCollisionIdentityFailurePropagatesWithoutCopying() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        do {
            _ = try await Resolver.install(originalName: "book.epub", collisionName: { _ in
                throw CocoaError(.fileReadCorruptFile)
            }, inspect: f.inspect, copyExclusively: f.copy)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue) }
        XCTAssertTrue(f.copies.isEmpty)
    }

    func testPreCancelledOperationDoesNotInspect() async throws {
        let f = try Files()
        let task = Task { @MainActor in try await f.install() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(f.inspections.isEmpty)
    }

    func testCancellationAfterInspectionPreventsCopy() async throws {
        let f = try Files()
        let task = Task { @MainActor in
            try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: { name in
                let result = try f.inspect(name)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }, copyExclusively: f.copy)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(f.copies.isEmpty)
    }

    func testCancellationWhileGeneratingSuffixStopsBeforeNextInspection() async throws {
        let f = try Files()
        try f.write("book.epub", "old")
        let task = Task { @MainActor in
            try await Resolver.install(originalName: "book.epub", collisionName: { ordinal in
                withUnsafeCurrentTask { $0?.cancel() }
                return f.name(ordinal)
            }, inspect: f.inspect, copyExclusively: f.copy)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.inspections, ["book.epub"])
        XCTAssertTrue(f.copies.isEmpty)
    }

    func testCancellationAfterSuccessfulCopyDoesNotDeleteCommittedFile() async throws {
        let f = try Files()
        let task = Task { @MainActor in
            try await Resolver.install(originalName: "book.epub", collisionName: f.name, inspect: f.inspect) { name in
                try f.copy(name)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let result = try await task.value
        XCTAssertEqual(result, "book.epub")
        XCTAssertEqual(try f.read(result), "new")
        XCTAssertEqual(f.copies, [result])
    }
}
