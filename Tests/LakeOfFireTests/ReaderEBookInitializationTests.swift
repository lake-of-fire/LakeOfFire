import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReaderEBookInitializationTests: XCTestCase {
    func testPreparationPrecedesRestoreAndPreservesZero() async throws {
        var stages = [String]()
        let (session, fraction) = try await ReaderEBookInitialization.prepareAndRestore(
            receiptBinding: 1,
            currentBinding: { 1 },
            prepare: { _ in stages.append("prepare"); return "session" },
            restore: { _ in stages.append("restore"); return Double(0) }
        )
        XCTAssertEqual(stages, ["prepare", "restore"])
        XCTAssertEqual(session, "session")
        XCTAssertEqual(fraction, 0)
    }

    func testReplacementDuringPreparationCannotReadItsRestore() async {
        var binding = 1
        var restored = false
        do {
            _ = try await ReaderEBookInitialization.prepareAndRestore(
                receiptBinding: 1,
                currentBinding: { binding },
                prepare: { _ in binding = 2; return "old-session" },
                restore: { _ in restored = true; return Double(0.5) }
            )
            XCTFail("Replacement consumed old initialization")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(restored)
    }

    func testUncooperativePreparationCannotReadRestoreAfterCancellation() async {
        var restored = false
        let task = Task { @MainActor in
            do {
                _ = try await ReaderEBookInitialization.prepareAndRestore(
                    receiptBinding: 1,
                    currentBinding: { 1 },
                    prepare: { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                        return "session"
                    },
                    restore: { _ in restored = true; return Double(0) }
                )
                XCTFail("Cancellation consumed preparation")
            } catch is CancellationError {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await task.value
        XCTAssertFalse(restored)
    }

    func testReplacementDuringRestoreCannotPublishItsResult() async {
        var binding = 1
        do {
            _ = try await ReaderEBookInitialization.prepareAndRestore(
                receiptBinding: 1,
                currentBinding: { binding },
                prepare: { _ in "session" },
                restore: { _ in binding = 2; return Double(0) }
            )
            XCTFail("Replacement received restore result")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
