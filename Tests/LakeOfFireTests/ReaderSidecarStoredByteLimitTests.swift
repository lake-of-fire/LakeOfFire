import Foundation
import XCTest
@testable import LakeOfFireReader

final class ReaderSidecarStoredByteLimitTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOversizedAndEmptyInsertionDoNotPublishTokens() throws {
        let store = ReaderExternalSegmentSidecarStore(directoryURL: try directory(), maximumEntryByteCount: 4)
        XCTAssertNil(store.insert(Data()))
        XCTAssertNil(store.insert(Data(repeating: 1, count: 5)))
        XCTAssertNotNil(store.insert(Data(repeating: 1, count: 4)))
    }

    func testReopenedStoreRejectsEntryAboveItsCurrentLimit() throws {
        let url = try directory()
        let writer = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: 8)
        let token = try XCTUnwrap(writer.insert(Data(repeating: 7, count: 8))).token
        let reader = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: 7)
        XCTAssertNil(reader.entry(for: token))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(token).path))
    }

    func testExactLimitSurvivesMemoryEvictionAndDiskRead() throws {
        let url = try directory()
        let bytes = Data(repeating: 3, count: 65_537)
        let writer = ReaderExternalSegmentSidecarStore(directoryURL: url, totalByteLimit: 1, maximumEntryByteCount: bytes.count)
        let token = try XCTUnwrap(writer.insert(bytes)).token
        XCTAssertEqual(writer.entry(for: token)?.data, bytes)
        let reader = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: bytes.count)
        XCTAssertEqual(reader.entry(for: token)?.data, bytes)
    }

    func testReplacedStoredBytesStillRequireContentAddressMatch() throws {
        let url = try directory()
        let writer = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: 8)
        let token = try XCTUnwrap(writer.insert(Data([1, 2, 3]))).token
        try Data([3, 2, 1]).write(to: url.appendingPathComponent(token), options: .atomic)
        let reader = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: 8)
        XCTAssertNil(reader.entry(for: token))
    }

    func testReinsertRepairsOversizedCorruptStoredObject() throws {
        let url = try directory()
        let bytes = Data([1, 2, 3])
        let writer = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: 4)
        let token = try XCTUnwrap(writer.insert(bytes)).token
        try Data(repeating: 0, count: 20).write(to: url.appendingPathComponent(token), options: .atomic)
        XCTAssertEqual(writer.insert(bytes)?.token, token)
        let reader = ReaderExternalSegmentSidecarStore(directoryURL: url, maximumEntryByteCount: 4)
        XCTAssertEqual(reader.entry(for: token)?.data, bytes)
    }
}
