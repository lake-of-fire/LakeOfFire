import JavaScriptCore
import SwiftUI
import XCTest
@testable import LakeOfFireReader

final class ReaderThemeMutationTests: XCTestCase {
    @MainActor
    func testRepeatedThemeDoesNotMutateMountedDocuments() async throws {
        let context = try makeContext()
        var appliedCount: Int?
        let evaluate: ReaderSettingsJavaScriptEvaluator = { script, duplicateInFrames in
            XCTAssertTrue(duplicateInFrames)
            context.exception = nil
            let result = context.evaluateScript(script)
            XCTAssertNil(context.exception)
            if let count = result?.forProperty("appliedCount")?.toInt32() {
                appliedCount = Int(count)
            } else {
                appliedCount = nil
            }
        }

        await applyReaderTheme(
            colorScheme: .light, lightModeTheme: .white, darkModeTheme: .gray,
            reason: "initial", hasAsyncCaller: true, evaluateJavaScript: evaluate
        )
        XCTAssertEqual(appliedCount, 2)
        XCTAssertEqual(context.evaluateScript("mutationCount")?.toInt32(), 10)

        await applyReaderTheme(
            colorScheme: .light, lightModeTheme: .white, darkModeTheme: .gray,
            reason: "scene-active", hasAsyncCaller: true, evaluateJavaScript: evaluate
        )
        XCTAssertEqual(appliedCount, 0)
        XCTAssertEqual(context.evaluateScript("mutationCount")?.toInt32(), 10)

        await applyReaderTheme(
            colorScheme: .dark, lightModeTheme: .white, darkModeTheme: .gray,
            reason: "color-scheme-change", hasAsyncCaller: true, evaluateJavaScript: evaluate
        )
        XCTAssertEqual(appliedCount, 2)
        XCTAssertEqual(context.evaluateScript("mutationCount")?.toInt32(), 16)
        XCTAssertEqual(context.evaluateScript("chapter.body.dataset.mnbColorScheme")?.toString(), "dark")
    }

    @MainActor
    func testNewExplicitDocumentReceivesThemeOnceAndMountedDocumentIsDeduplicated() async throws {
        let context = try makeContext()
        await applyReaderTheme(
            colorScheme: .dark, lightModeTheme: .beige, darkModeTheme: .black,
            reason: "initial", hasAsyncCaller: true
        ) { script, _ in
            context.evaluateScript(script)
            XCTAssertNil(context.exception)
        }

        context.evaluateScript("globalThis.detached = makeDocument()")
        let first = context.evaluateScript("manabiApplyReaderThemeToEbookDocuments('load', detached)")
        XCTAssertNil(context.exception)
        XCTAssertEqual(first?.forProperty("appliedCount")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("mutationCount")?.toInt32(), 15)
        XCTAssertEqual(context.evaluateScript("detached.body.dataset.mnbLightTheme")?.toString(), "beige")
        XCTAssertEqual(context.evaluateScript("detached.body.dataset.mnbDarkTheme")?.toString(), "black")

        let second = context.evaluateScript("manabiApplyReaderThemeToEbookDocuments('repeat', chapter)")
        XCTAssertNil(context.exception)
        XCTAssertEqual(second?.forProperty("appliedCount")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("mutationCount")?.toInt32(), 15)
    }

    @MainActor
    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        // Count observable mutations; execute the production evaluator output directly.
        context.evaluateScript("""
            globalThis.mutationCount = 0;
            function makeStyle() {
                const values = {};
                return {
                    getPropertyValue: key => values[key] || '',
                    setProperty: (key, value) => { mutationCount++; values[key] = value; }
                };
            }
            function makeDocument() {
                return {
                    body: {
                        dataset: new Proxy({}, {
                            set: (target, key, value) => {
                                mutationCount++; target[key] = value; return true;
                            }
                        }),
                        style: makeStyle()
                    },
                    documentElement: { style: makeStyle() }
                };
            }
            globalThis.document = makeDocument();
            globalThis.chapter = makeDocument();
            globalThis.reader = { view: { renderer: {
                getContents: () => [{ doc: chapter }, { document: chapter }]
            } } };
            """)
        XCTAssertNil(context.exception)
        return context
    }
}
