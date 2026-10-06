import Foundation
import XCTest
#if canImport(LakeOfFireContent)
@testable import LakeOfFireContent
#else
@testable import EBookNamespace
#endif

final class ReaderEBookPackageNamespaceTests: XCTestCase {
    private func conflict(_ files: [String], directories: [String] = []) throws -> String? {
        try ReaderEBookPackageNamespace.conflictingPath(in:
            files.map { (path: $0, isDirectory: false) } + directories.map { (path: $0, isDirectory: true) })
    }
    func testDistinctNamesAndExplicitParentsAccepted() throws {
        XCTAssertNil(try conflict(["OPS/a.xhtml", "OPS/sub/b.xhtml", "META-INF/container.xml"],
                                  directories: ["OPS", "OPS/sub", "META-INF", "empty"]))
    }
    func testCaseOnlyLeafAliasesRejected() throws {
        XCTAssertNotNil(try conflict(["OPS/Book.xhtml", "OPS/book.xhtml"]))
    }
    func testCaseOnlyImplicitParentAliasesRejected() throws {
        XCTAssertNotNil(try conflict(["OPS/a.xhtml", "ops/b.xhtml"]))
    }
    func testCaseOnlyExplicitParentAliasRejected() throws {
        XCTAssertNotNil(try conflict(["ops/a.xhtml"], directories: ["OPS"]))
    }
    func testCanonicalParentAliasesRejectedWithDistinctLeaves() throws {
        XCTAssertNotNil(try conflict(["caf\u{e9}/a", "cafe\u{301}/b"]))
    }
    func testFullCaseFoldingExpansionIsNotJustLowercasing() throws {
        XCTAssertNotNil(try conflict(["Stra\u{df}e/a", "STRASSE/b"]))
        XCTAssertNotNil(try conflict(["OPS/\u{3c2}.xhtml", "OPS/\u{3c3}.xhtml"]))
    }
    func testDiacriticsAndDifferentJapaneseNamesRemainDistinct() throws {
        XCTAssertNil(try conflict(["cafe/a", "caf\u{e9}/b", "本/一.xhtml", "本/二.xhtml"]))
    }
    func testFileParentCollisionIsNotHiddenBySiblingPrefix() throws {
        XCTAssertNotNil(try conflict(["a", "a-else", "a/child"]))
        XCTAssertNotNil(try conflict(["A", "a-else", "a/child"]))
    }
    func testNoSharedParentMeansSameLeafSpellingIsAllowed() throws {
        XCTAssertNil(try conflict(["A/Book.xhtml", "B/book.xhtml"]))
    }
    func testDuplicateFileOrDirectoryRejected() throws {
        XCTAssertNotNil(try conflict(["OPS/a", "OPS/a"]))
        XCTAssertNotNil(try conflict([], directories: ["OPS", "OPS"]))
        XCTAssertNotNil(try conflict(["OPS"], directories: ["OPS"]))
    }
    func testEntryOrderDoesNotChangeDetection() throws {
        let paths = ["a", "a-else", "a/child", "B/one", "b/two"]
        let expected = try conflict(paths)
        XCTAssertNotNil(expected)
        for index in paths.indices {
            let rotated = Array(paths[index...]) + Array(paths[..<index])
            XCTAssertEqual(try conflict(rotated), expected)
            XCTAssertEqual(try conflict(rotated.reversed()), expected)
        }
    }
    func testDeepPathsDoNotRequireAncestorMaterialization() throws {
        let prefix = String(repeating: "a/", count: 1_000)
        XCTAssertNil(try conflict([prefix + "first", prefix + "second"]))
        XCTAssertNotNil(try conflict([prefix + "First", prefix + "first"]))
    }
    func testEmptyNamespaceAndSingleEntryAccepted() throws {
        XCTAssertNil(try conflict([]))
        XCTAssertNil(try conflict(["book.opf"]))
    }
    func testCancellationDoesNotReturnAnAcceptedNamespace() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try self.conflict(["OPS/a", "OPS/b"])
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }
}

extension ReaderEBookPackageNamespaceTests {
    func testGeneratedNamespacesAgreeWithAllPairsReference() throws {
        typealias Item = (path: String, isDirectory: Bool)
        let names = ["a", "A", "a-else", "b", "B", "Straße", "STRASSE", "café", "cafe\u{301}", "本"]
        func folded(_ component: Substring) -> Data {
            Data(String(component).decomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping.utf8)
        }
        func reference(_ values: [Item]) -> Bool {
            for i in values.indices {
                for j in values.indices where j > i {
                    let a = values[i].path.split(separator: "/"), b = values[j].path.split(separator: "/")
                    var shared = 0
                    while shared < min(a.count, b.count), folded(a[shared]) == folded(b[shared]) {
                        if !a[shared].utf8.elementsEqual(b[shared].utf8) { return true }
                        shared += 1
                    }
                    if shared == a.count && (shared == b.count || !values[i].isDirectory) { return true }
                    if shared == b.count && !values[j].isDirectory { return true }
                }
            }
            return false
        }
        var state: UInt64 = 0x96f27c
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(bound))
        }
        for _ in 0..<1_000 {
            var entries = [Item]()
            for _ in 0..<next(10) {
                let path = (0..<(1 + next(4))).map { _ in names[next(names.count)] }.joined(separator: "/")
                entries.append((path, next(3) == 0))
            }
            XCTAssertEqual(try ReaderEBookPackageNamespace.conflictingPath(in: entries) != nil, reference(entries),
                           "Mismatch for \(entries)")
        }
    }
}
