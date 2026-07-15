import XCTest
import WebKit
@testable import LakeOfFireReader

@MainActor
final class ReaderBuiltInUserScriptsTests: XCTestCase {
    func testDocumentStateScriptRunsAtDocumentEndInMainFrame() {
        let script = ReaderDocStateUserScript().userScript

        XCTAssertEqual(script.injectionTime, .atDocumentEnd)
        XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertEqual(script.world, .page)
    }

    func testUnhandledTapScriptRunsAtDocumentEndInEveryFrame() {
        let script = ReaderUnhandledTapUserScript().userScript

        XCTAssertEqual(script.injectionTime, .atDocumentEnd)
        XCTAssertFalse(script.isForMainFrameOnly)
        XCTAssertEqual(script.world, .page)
    }
}
