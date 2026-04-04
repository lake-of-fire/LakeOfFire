import Foundation
import XCTest

final class EbookRendererHarnessSmokeTests: XCTestCase {
    func testHarnessSmokePassesGeneratedJapaneseEPUB() throws {
        let fixtureDirectoryURL = try makeFixtureDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        }

        let epubURL = try makeMinimalEPUB(at: fixtureDirectoryURL)
        let smokeResult = try runHarnessSmoke(arguments: ["--smoke-test", "--smoke-timeout=24", epubURL.path])
        let summary = try extractSmokeSummary(from: smokeResult.combinedOutput)
        assertPassingSmokeResult(smokeResult, summary: summary)
        XCTAssertEqual(smokeSummaryString(at: ["smokeTest", "writingDirection"], in: summary), "original")
        XCTAssertEqual(smokeSummaryBool(at: ["smokeTest", "usesViewLength"], in: summary), true)
        XCTAssertEqual(smokeSummaryNumber(at: ["smokeTest", "explicitPageLength"], in: summary), 0)
        XCTAssertEqual(smokeSummaryString(at: ["nativePagination", "state", "storedPageLength"], in: summary), "0.0")
        assertNavigationCoverage(summary)
        assertButtonNavigationProbe(summary)
        assertJumpProbe(summary)
        assertTOCJumpProbe(summary)
        assertProgressJumpProbe(summary)
        assertRestoreProbe(summary)
        assertFinishStartOverProbe(summary)
        assertNativePaginationState(summary)
        assertRuntimePaginationProbe(summary)
        assertPaginationToggleProbe(summary)
        assertResizeProbe(summary, expectVertical: false)
        assertUserFacingPageUI(summary)
        assertLayoutLooksSane(summary)
        assertSectionLayoutDiagnostics(summary, expectVertical: false)
    }

    func testHarnessSmokePassesVerticalWritingEPUBWithExplicitPageLength() throws {
        let fixtureDirectoryURL = try makeFixtureDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        }

        let epubURL = try makeMinimalEPUB(at: fixtureDirectoryURL, verticalWriting: true)
        let smokeResult = try runHarnessSmoke(
            arguments: [
                "--smoke-test",
                "--smoke-timeout=24",
                "--smoke-page-length=700",
                "--smoke-writing-direction=vertical",
                epubURL.path,
            ]
        )
        let summary = try extractSmokeSummary(from: smokeResult.combinedOutput)
        assertPassingSmokeResult(smokeResult, summary: summary)
        XCTAssertEqual(smokeSummaryBool(at: ["smokeTest", "usesViewLength"], in: summary), false)
        XCTAssertEqual(smokeSummaryNumber(at: ["smokeTest", "explicitPageLength"], in: summary), 700)
        XCTAssertEqual(smokeSummaryString(at: ["smokeTest", "writingDirection"], in: summary), "vertical")
        XCTAssertEqual(smokeSummaryString(at: ["nativePagination", "state", "storedPageLength"], in: summary), "700.0")
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "writingDirectionSnapshot", "writingDirectionOverride"], in: summary), "vertical")
        XCTAssertEqual(smokeSummaryBool(at: ["jsProbe", "writingDirectionSnapshot", "vertical"], in: summary), true)
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "writingDirectionSnapshot", "writingMode"], in: summary), "vertical-rl")
        assertNavigationCoverage(summary)
        assertJumpProbe(summary)
        assertButtonNavigationProbe(summary)
        assertTOCJumpProbe(summary)
        assertProgressJumpProbe(summary)
        assertRestoreProbe(summary)
        assertFinishStartOverProbe(summary)
        assertNativePaginationState(summary)
        assertRuntimePaginationProbe(summary)
        assertPaginationToggleProbe(summary)
        assertResizeProbe(summary, expectVertical: true, expectedWritingMode: "vertical-rl")
        assertVerticalTallSpreadProbe(summary)
        assertUserFacingPageUI(summary)
        assertLayoutLooksSane(summary)
        assertSectionLayoutDiagnostics(summary, expectVertical: true, expectedWritingMode: "vertical-rl")
    }

    func testHarnessSmokePassesHorizontalRTLEPUB() throws {
        let fixtureDirectoryURL = try makeFixtureDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        }

        let epubURL = try makeMinimalEPUB(
            at: fixtureDirectoryURL,
            languageCode: "ar",
            creator: "نجيب محفوظ",
            title: "اختبار القارئ",
            bodyDirection: "rtl",
            chapterTitles: ("الفصل الأول", "الفصل الثاني"),
            chapterParagraphs: (
                [
                    "في مساء هادئ جلس القارئ يتابع السطور الأولى في صفحة تمتد من اليمين إلى اليسار.",
                    "كان الهدف من هذا الملف التجريبي أن يثبت أن مسار العرض نفسه يحافظ على الاتجاه الدلالي الصحيح."
                ],
                [
                    "ثم انتقل إلى الفصل التالي ليتأكد من أن التنقل والتقدّم يعكسان ترتيب الصفحات المتوقع.",
                    "كما يجب أن تبقى إعادة تطبيق الترقيم على المضيف نفسه من دون إعادة تركيب شجرة العرض."
                ]
            )
        )
        let smokeResult = try runHarnessSmoke(
            arguments: [
                "--smoke-test",
                "--smoke-timeout=24",
                epubURL.path,
            ]
        )
        let summary = try extractSmokeSummary(from: smokeResult.combinedOutput)
        assertPassingSmokeResult(smokeResult, summary: summary)
        XCTAssertEqual(smokeSummaryBool(at: ["jsProbe", "writingDirectionSnapshot", "rtl"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["jsProbe", "writingDirectionSnapshot", "vertical"], in: summary), false)
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "writingDirectionSnapshot", "writingMode"], in: summary), "horizontal-rtl")
        assertNavigationCoverage(summary)
        assertJumpProbe(summary)
        assertButtonNavigationProbe(summary)
        assertTOCJumpProbe(summary)
        assertProgressJumpProbe(summary)
        assertRestoreProbe(summary)
        assertFinishStartOverProbe(summary)
        assertNativePaginationState(summary)
        assertRuntimePaginationProbe(summary)
        assertPaginationToggleProbe(summary)
        assertResizeProbe(summary, expectVertical: false)
        assertUserFacingPageUI(summary)
        assertLayoutLooksSane(summary)
        assertSectionLayoutDiagnostics(summary, expectVertical: false)
    }

    func testHarnessSmokePassesLongChapterEPUBWithMultipleNativePages() throws {
        let fixtureDirectoryURL = try makeFixtureDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        }

        let longChapterParagraphs = makeLongChapterParagraphs()
        let epubURL = try makeMinimalEPUB(
            at: fixtureDirectoryURL,
            additionalCSS: """
            body {
              font-size: 30px;
              line-height: 2.1;
            }
            h1 {
              font-size: 38px;
              margin-bottom: 1.2em;
            }
            p {
              margin-bottom: 1.1em;
            }
            """,
            chapterParagraphs: (longChapterParagraphs, longChapterParagraphs)
        )
        let smokeResult = try runHarnessSmoke(
            arguments: [
                "--smoke-test",
                "--smoke-timeout=30",
                "--smoke-page-length=220",
                epubURL.path,
            ]
        )
        let summary = try extractSmokeSummary(from: smokeResult.combinedOutput)
        assertPassingSmokeResult(smokeResult, summary: summary)
        assertNavigationProbe(summary)
        assertButtonNavigationProbe(summary)
        assertJumpProbe(summary)
        assertTOCJumpProbe(summary)
        assertProgressJumpProbe(summary)
        assertRestoreProbe(summary)
        assertFinishStartOverProbe(summary)
        assertNativePaginationState(summary)
        assertRuntimePaginationProbe(summary)
        assertPaginationToggleProbe(summary)
        assertResizeProbe(summary, expectVertical: false)
        assertUserFacingPageUI(summary)
        assertLayoutLooksSane(summary)
        assertSectionLayoutDiagnostics(summary, expectVertical: false, requireComplete: false)
        assertLongChapterPagination(summary)
    }

    func testHarnessSmokeSurfacesLongChapterDiagnosticsForRashomonIfAvailable() throws {
        let rashomonURL = URL(fileURLWithPath: "/Users/alex/Downloads/[芥川龍之介] 羅生門.epub")
        guard FileManager.default.fileExists(atPath: rashomonURL.path) else {
            throw XCTSkip("Local Rashomon EPUB is not available at \(rashomonURL.path)")
        }

        let smokeResult = try runHarnessSmoke(
            arguments: [
                "--smoke-test",
                "--smoke-timeout=30",
                rashomonURL.path,
            ]
        )
        let summary = try extractSmokeSummary(from: smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "ebookViewerInitialized"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "ebookViewerLoaded"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryInt(at: ["jsProbe", "iframeCount"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["jsProbe", "hasSectionLayoutController"], in: summary), true, smokeResult.combinedOutput)
        guard smokeSummaryBool(at: ["longChapterProbe", "chapter2Reached"], in: summary) == true else {
            throw XCTSkip("Rashomon sample did not reach a deterministic second-section jump target in smoke mode")
        }
        assertLongChapterPagination(summary)
    }

    private func makeFixtureDirectory() throws -> URL {
        let fixtureDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EbookRendererHarnessSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)
        return fixtureDirectoryURL
    }

    private func runHarnessSmoke(arguments: [String]) throws -> ProcessResult {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harnessURL = packageRootURL
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("arm64-apple-macosx", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("EbookRendererHarness")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: harnessURL.path), harnessURL.path)

        return try runProcess(
            executableURL: harnessURL,
            arguments: arguments,
            currentDirectoryURL: packageRootURL,
            timeout: 90
        )
    }

    private func assertPassingSmokeResult(_ smokeResult: ProcessResult, summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeResult.exitCode, 0, smokeResult.combinedOutput)
        XCTAssertTrue(smokeResult.combinedOutput.contains("smoke.pass: all smoke gates passed"), smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["overallSuccess"], in: summary), true, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["gates", "gate1SameDocumentMount"], in: summary), true, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["gates", "gate2NativePaginationReadback"], in: summary), true, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["gates", "gate3NavigationFacade"], in: summary), true, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["gates", "gate4AppFacingContract"], in: summary), true, smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "ebookViewerInitialized"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "ebookViewerLoaded"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "updateCurrentContentPage"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "updateReadingProgress"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["events", "ebookNavigationVisibility"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryInt(at: ["jsProbe", "iframeCount"], in: summary), 0, smokeResult.combinedOutput)
        XCTAssertEqual(smokeSummaryBool(at: ["jsProbe", "hasSectionLayoutController"], in: summary), true, smokeResult.combinedOutput)
        XCTAssertNotEqual(smokeSummaryString(at: ["jsProbe", "contentURL"], in: summary), "", smokeResult.combinedOutput)
    }

    private func assertRuntimePaginationProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["runtimePaginationProbe", "gapChanged"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["runtimePaginationProbe", "sameMountedHost"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["runtimePaginationProbe", "sameAppliedHost"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["runtimePaginationProbe", "appliedToMountedHost"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["runtimePaginationProbe", "pageCountStable"], in: summary), true)
        XCTAssertGreaterThan(smokeSummaryNumber(at: ["runtimePaginationProbe", "requestedGap"], in: summary) ?? 0, 24)
        XCTAssertNotEqual(smokeSummaryString(at: ["runtimePaginationProbe", "before", "mountedHostIdentifier"], in: summary), "nil")
        XCTAssertEqual(
            smokeSummaryString(at: ["runtimePaginationProbe", "before", "mountedHostIdentifier"], in: summary),
            smokeSummaryString(at: ["runtimePaginationProbe", "after", "mountedHostIdentifier"], in: summary)
        )
    }

    private func assertNavigationProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["navigationProbe", "nextAdvanced"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["navigationProbe", "prevReturned"], in: summary), true)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["navigationProbe", "updateReadingProgressDelta"], in: summary), 1)
    }

    private func assertNavigationCoverage(_ summary: [String: Any], line: UInt = #line) {
        if smokeSummaryBool(at: ["gateDiagnostics", "allowsSinglePageNavigationFallback"], in: summary) == true {
            XCTAssertLessThanOrEqual(smokeSummaryInt(at: ["gateDiagnostics", "initialSectionPageCount"], in: summary), 1)
            XCTAssertEqual(smokeSummaryBool(at: ["buttonNavigationProbe", "nextAdvanced"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["buttonNavigationProbe", "prevReturned"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["jumpProbe", "chapter2Reached"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["jumpProbe", "chapter1Returned"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["tocJumpProbe", "chapter2Reached"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["tocJumpProbe", "chapter1Returned"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["progressJumpProbe", "endReached"], in: summary), true)
            XCTAssertEqual(smokeSummaryBool(at: ["progressJumpProbe", "startReturned"], in: summary), true)
            return
        }

        assertNavigationProbe(summary, line: line)
    }

    private func assertJumpProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["jumpProbe", "chapter2Reached"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["jumpProbe", "chapter1Returned"], in: summary), true)
        XCTAssertEqual(smokeSummaryString(at: ["jumpProbe", "chapter2Target"], in: summary), "OEBPS/chapter2.xhtml")
        XCTAssertEqual(smokeSummaryString(at: ["jumpProbe", "chapter1Target"], in: summary), "OEBPS/chapter1.xhtml")
    }

    private func assertProgressJumpProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["progressJumpProbe", "endReached"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["progressJumpProbe", "startReturned"], in: summary), true)
        XCTAssertEqual(smokeSummaryNumber(at: ["progressJumpProbe", "jumpToEndFraction"], in: summary), 1)
        XCTAssertEqual(smokeSummaryNumber(at: ["progressJumpProbe", "jumpToStartFraction"], in: summary), 0)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["progressJumpProbe", "updateCurrentContentPageDelta"], in: summary), 1)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["progressJumpProbe", "updateReadingProgressDelta"], in: summary), 1)
    }

    private func assertButtonNavigationProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["buttonNavigationProbe", "nextAdvanced"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["buttonNavigationProbe", "prevReturned"], in: summary), true)
    }

    private func assertTOCJumpProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["tocJumpProbe", "chapter2Reached"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["tocJumpProbe", "chapter1Returned"], in: summary), true)
        XCTAssertEqual(smokeSummaryString(at: ["tocJumpProbe", "chapter2Target"], in: summary), "OEBPS/chapter2.xhtml")
        XCTAssertEqual(smokeSummaryString(at: ["tocJumpProbe", "chapter1Target"], in: summary), "OEBPS/chapter1.xhtml")
    }

    private func assertRestoreProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["restoreProbe", "restoredToSecondChapter"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["restoreProbe", "restoredCFIPreserved"], in: summary), true)
        XCTAssertTrue(
            (smokeSummaryString(at: ["restoreProbe", "beforeReloadContentPageURL"], in: summary) ?? "").contains("chapter2.xhtml")
        )
        XCTAssertTrue(
            (smokeSummaryString(at: ["restoreProbe", "afterReloadContentPageURL"], in: summary) ?? "").contains("chapter2.xhtml")
        )
        XCTAssertFalse((smokeSummaryString(at: ["restoreProbe", "beforeReloadCFI"], in: summary) ?? "").isEmpty)
        XCTAssertFalse((smokeSummaryString(at: ["restoreProbe", "afterReloadCFI"], in: summary) ?? "").isEmpty)
    }

    private func assertFinishStartOverProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["finishStartOverProbe", "finishMessageObserved"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["finishStartOverProbe", "startOverMessageObserved"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["finishStartOverProbe", "restartReturnedToFirstChapter"], in: summary), true)
        XCTAssertTrue(
            (smokeSummaryString(at: ["finishStartOverProbe", "afterRestartContentPageURL"], in: summary) ?? "").contains("chapter1.xhtml")
        )
    }

    private func assertPaginationToggleProbe(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["paginationToggleProbe", "disabledApplied"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["paginationToggleProbe", "restoredApplied"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["paginationToggleProbe", "sameMountedHostAcrossToggle"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["paginationToggleProbe", "sameAppliedHostAcrossToggle"], in: summary), true)
        XCTAssertEqual(
            smokeSummaryString(at: ["paginationToggleProbe", "before", "mountedHostIdentifier"], in: summary),
            smokeSummaryString(at: ["paginationToggleProbe", "restored", "mountedHostIdentifier"], in: summary)
        )
    }

    private func assertResizeProbe(
        _ summary: [String: Any],
        expectVertical: Bool,
        expectedWritingMode: String? = nil,
        line: UInt = #line
    ) {
        XCTAssertEqual(smokeSummaryString(at: ["resizeProbe", "afterPreset"], in: summary), "macBook")
        XCTAssertEqual(smokeSummaryInt(at: ["resizeProbe", "after", "shellMetrics", "innerWidth"], in: summary), 1280)
        XCTAssertEqual(smokeSummaryInt(at: ["resizeProbe", "after", "shellMetrics", "innerHeight"], in: summary), 900)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "sameMountedHost"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "sameAppliedHost"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "pageCountPositive"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "layoutSizeApplied"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "layoutDiagnosticsPresent"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "chunkCountPositive"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["resizeProbe", "columnCountPositive"], in: summary), true)
        XCTAssertEqual(
            smokeSummaryString(at: ["resizeProbe", "beforeState", "mountedHostIdentifier"], in: summary),
            smokeSummaryString(at: ["resizeProbe", "afterState", "mountedHostIdentifier"], in: summary)
        )
        assertSectionLayoutDiagnostics(
            summary,
            at: ["resizeProbe", "after", "sectionLayoutDiagnostics"],
            expectVertical: expectVertical,
            expectedWritingMode: expectedWritingMode,
            requireComplete: false
        )
    }

    private func assertLayoutLooksSane(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "innerWidth"], in: summary), 1180)
        XCTAssertEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "innerHeight"], in: summary), 820)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "readerStageMetrics", "offsetWidth"], in: summary), 900)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "readerStageMetrics", "offsetHeight"], in: summary), 600)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "stageViewMetrics", "offsetWidth"], in: summary), 900)
        XCTAssertGreaterThanOrEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "stageViewMetrics", "offsetHeight"], in: summary), 600)
        XCTAssertEqual(smokeSummaryInt(at: ["jsProbe", "shellMetrics", "navBarMetrics", "offsetHeight"], in: summary), 63)
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "shellMetrics", "navBarMetrics", "computedHeight"], in: summary), "63px")
        XCTAssertGreaterThanOrEqual(
            smokeSummaryInt(at: ["jsProbe", "shellMetrics", "readerStageMetrics", "offsetWidth"], in: summary),
            smokeSummaryInt(at: ["jsProbe", "shellMetrics", "stageViewMetrics", "offsetWidth"], in: summary)
        )
        XCTAssertGreaterThanOrEqual(
            smokeSummaryInt(at: ["jsProbe", "shellMetrics", "readerStageMetrics", "offsetHeight"], in: summary),
            smokeSummaryInt(at: ["jsProbe", "shellMetrics", "stageViewMetrics", "offsetHeight"], in: summary)
        )
        XCTAssertGreaterThanOrEqual(
            smokeSummaryInt(at: ["jsProbe", "shellMetrics", "readerContentMetrics", "offsetHeight"], in: summary),
            smokeSummaryInt(at: ["jsProbe", "shellMetrics", "readerStageMetrics", "offsetHeight"], in: summary)
        )
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "shellMetrics", "stageViewMetrics", "computedDisplay"], in: summary), "block")
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "shellMetrics", "readerStageMetrics", "computedPosition"], in: summary), "absolute")
    }

    private func assertSectionLayoutDiagnostics(
        _ summary: [String: Any],
        at basePath: [String] = ["jsProbe", "sectionLayoutDiagnostics"],
        expectVertical: Bool,
        expectedWritingMode: String? = nil,
        requireComplete: Bool = true,
        line: UInt = #line
    ) {
        let diagnostics = smokeSummaryDictionary(at: basePath + ["layoutDiagnostics"], in: summary)
        XCTAssertNotNil(diagnostics, "Missing section layout diagnostics")
        XCTAssertGreaterThan(smokeSummaryInt(at: basePath + ["pageCount"], in: summary), 0)
        if requireComplete {
            XCTAssertEqual(
                smokeSummaryBool(at: basePath + ["layoutDiagnostics", "layoutComplete"], in: summary),
                true
            )
        }
        XCTAssertGreaterThan(smokeSummaryInt(at: basePath + ["layoutDiagnostics", "pageRecordCount"], in: summary), 0)
        XCTAssertGreaterThan(smokeSummaryInt(at: basePath + ["layoutDiagnostics", "currentPageChunkCount"], in: summary), 0)
        XCTAssertGreaterThan(smokeSummaryInt(at: basePath + ["layoutDiagnostics", "maxPageChunkCount"], in: summary), 0)
        XCTAssertGreaterThan(smokeSummaryInt(at: basePath + ["layoutDiagnostics", "columnCount"], in: summary), 0)
        XCTAssertEqual(smokeSummaryBool(at: basePath + ["layoutDiagnostics", "vertical"], in: summary), expectVertical)

        let writingMode = smokeSummaryString(
            at: basePath + ["layoutDiagnostics", "writingMode"],
            in: summary
        ) ?? ""
        XCTAssertFalse(writingMode.isEmpty)
        if let expectedWritingMode {
            XCTAssertEqual(writingMode, expectedWritingMode)
        } else if expectVertical {
            XCTAssertTrue(writingMode.hasPrefix("vertical"), writingMode)
        } else {
            XCTAssertTrue(writingMode.hasPrefix("horizontal"), writingMode)
        }
    }

    private func assertUserFacingPageUI(_ summary: [String: Any], line: UInt = #line) {
        let primaryLabel = smokeSummaryString(at: ["jsProbe", "userFacingPageUI", "primaryLabelFull"], in: summary) ?? ""
        let compactLabel = smokeSummaryString(at: ["jsProbe", "userFacingPageUI", "primaryLabelCompact"], in: summary) ?? ""
        let progressSliderTitle = smokeSummaryString(at: ["jsProbe", "userFacingPageUI", "progressSliderTitle"], in: summary) ?? ""

        XCTAssertFalse(primaryLabel.localizedCaseInsensitiveContains("loc"), primaryLabel)
        XCTAssertFalse(compactLabel.localizedCaseInsensitiveContains("loc"), compactLabel)
        XCTAssertFalse(progressSliderTitle.localizedCaseInsensitiveContains("loc"), progressSliderTitle)
        XCTAssertTrue(primaryLabel.isEmpty || primaryLabel.localizedCaseInsensitiveContains("page"), primaryLabel)
        XCTAssertTrue(compactLabel.isEmpty || compactLabel.localizedCaseInsensitiveContains("page"), compactLabel)
        XCTAssertEqual(smokeSummaryBool(at: ["jsProbe", "userFacingPageUI", "jumpUnitSelectPresent"], in: summary), false)
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "userFacingPageUI", "jumpInputMin"], in: summary), "0")
        XCTAssertEqual(smokeSummaryString(at: ["jsProbe", "userFacingPageUI", "jumpInputMax"], in: summary), "100")
    }

    private func assertNativePaginationState(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertNotEqual(smokeSummaryString(at: ["nativePagination", "state", "mountedHostIdentifier"], in: summary), "nil")
        XCTAssertNotEqual(smokeSummaryString(at: ["nativePagination", "state", "appliedHostIdentifier"], in: summary), "nil")
        XCTAssertEqual(smokeSummaryString(at: ["nativePagination", "state", "mountedHostIdentifier"], in: summary), smokeSummaryString(at: ["nativePagination", "state", "appliedHostIdentifier"], in: summary))
        XCTAssertEqual(smokeSummaryString(at: ["nativePagination", "state", "isAppliedToMountedHost"], in: summary), "true")
        XCTAssertNotEqual(smokeSummaryString(at: ["nativePagination", "state", "pageCount"], in: summary), "nil")
        XCTAssertNotEqual(smokeSummaryString(at: ["nativePagination", "state", "lastApplyReason"], in: summary), "nil")
        XCTAssertGreaterThan(smokeSummaryInt(at: ["nativePagination", "initialPageCount"], in: summary), 0)
        XCTAssertGreaterThan(smokeSummaryInt(at: ["nativePagination", "stablePageCount"], in: summary), 0)
    }

    private func assertLongChapterPagination(_ summary: [String: Any], line: UInt = #line) {
        XCTAssertEqual(smokeSummaryBool(at: ["longChapterProbe", "chapter2Reached"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["longChapterProbe", "sameMountedHost"], in: summary), true)
        XCTAssertEqual(smokeSummaryBool(at: ["longChapterProbe", "sameAppliedHost"], in: summary), true)
        XCTAssertGreaterThan(
            smokeSummaryInt(at: ["longChapterProbe", "afterJumpToSecond", "navDiagnostics", "lastKnownLocationTotal"], in: summary),
            1
        )
        XCTAssertGreaterThan(smokeSummaryInt(at: ["longChapterProbe", "nativePageCountAfterJump"], in: summary), 0)
        let primaryLabel = smokeSummaryString(at: ["longChapterProbe", "afterJumpToSecond", "userFacingPageUI", "primaryLabelFull"], in: summary) ?? ""
        XCTAssertTrue(primaryLabel.contains("of"), primaryLabel)
        XCTAssertFalse(primaryLabel.localizedCaseInsensitiveContains("loc"), primaryLabel)
        XCTAssertFalse(primaryLabel.contains("Page 1 of 1"), primaryLabel)
        XCTAssertGreaterThan(
            smokeSummaryInt(
                at: ["longChapterProbe", "afterEnsurePageBuilt", "sectionLayoutDiagnostics", "pageCount"],
                in: summary
            ),
            0
        )
        assertSectionLayoutDiagnostics(
            summary,
            at: ["longChapterProbe", "wideViewportSpreadProbe", "sectionLayoutDiagnostics"],
            expectVertical: false,
            requireComplete: false
        )
        XCTAssertEqual(
            smokeSummaryInt(at: ["longChapterProbe", "wideViewportSpreadProbe", "shellMetrics", "innerWidth"], in: summary),
            1280
        )
        XCTAssertEqual(
            smokeSummaryInt(at: ["longChapterProbe", "wideViewportSpreadProbe", "shellMetrics", "innerHeight"], in: summary),
            900
        )
        let maxPageChunkCount = smokeSummaryInt(
            at: ["longChapterProbe", "wideViewportSpreadProbe", "sectionLayoutDiagnostics", "layoutDiagnostics", "maxPageChunkCount"],
            in: summary
        )
        XCTAssertGreaterThan(maxPageChunkCount, 0)
        let spreadCandidateDetected = smokeSummaryBool(
            at: ["longChapterProbe", "wideViewportSpreadProbe", "sectionLayoutDiagnostics", "layoutDiagnostics", "spreadCandidateDetected"],
            in: summary
        ) == true
        if spreadCandidateDetected {
            XCTAssertGreaterThan(maxPageChunkCount, 1)
        }
    }

    private func assertVerticalTallSpreadProbe(_ summary: [String: Any], line: UInt = #line) {
        assertSectionLayoutDiagnostics(
            summary,
            at: ["verticalTallSpreadProbe", "sectionLayoutDiagnostics"],
            expectVertical: true,
            expectedWritingMode: "vertical-rl",
            requireComplete: false
        )
        XCTAssertEqual(
            smokeSummaryInt(at: ["verticalTallSpreadProbe", "shellMetrics", "innerWidth"], in: summary),
            820
        )
        XCTAssertEqual(
            smokeSummaryInt(at: ["verticalTallSpreadProbe", "shellMetrics", "innerHeight"], in: summary),
            1180
        )
        let maxPageChunkCount = smokeSummaryInt(
            at: ["verticalTallSpreadProbe", "sectionLayoutDiagnostics", "layoutDiagnostics", "maxPageChunkCount"],
            in: summary
        )
        XCTAssertGreaterThan(maxPageChunkCount, 0)
        let spreadCandidateDetected = smokeSummaryBool(
            at: ["verticalTallSpreadProbe", "sectionLayoutDiagnostics", "layoutDiagnostics", "spreadCandidateDetected"],
            in: summary
        ) == true
        if spreadCandidateDetected {
            XCTAssertGreaterThan(maxPageChunkCount, 1)
        }
    }

    private func makeMinimalEPUB(
        at rootURL: URL,
        verticalWriting: Bool = false,
        languageCode: String = "ja",
        creator: String = "芥川龍之介",
        title: String = "羅生門 テスト",
        bodyDirection: String? = nil,
        pageProgressionDirection: String? = nil,
        additionalCSS: String? = nil,
        chapterTitles: (String, String) = ("第一章", "第二章"),
        chapterParagraphs: ([String], [String]) = (
            [
                "ある日の暮方の事である。ひとりの下人が、羅生門の下で雨やみを待っていた。",
                "広い門の下には、この男のほかに誰もいない。ただ、所々丹塗の剥げた、大きな円柱に、蟋蟀が一匹とまっている。"
            ],
            [
                "下人は、七段ある石段のいちばん上の段に洗いざらした紺の襖の尻を据えて、右の頬に出来た、大きな面皰を気にしながら、ぼんやり、雨の降るのを眺めていた。",
                "作者はさっき、「下人が雨やみを待っていた」と書いた。しかし下人は、雨がやんでも、格別どうしようという当てはない。"
            ]
        )
    ) throws -> URL {
        let metaInfURL = rootURL.appendingPathComponent("META-INF", isDirectory: true)
        let oebpsURL = rootURL.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInfURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebpsURL, withIntermediateDirectories: true)

        try "application/epub+zip".write(to: rootURL.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(
            to: metaInfURL.appendingPathComponent("container.xml"),
            atomically: true,
            encoding: .utf8
        )

        let resolvedPageProgressionDirection = pageProgressionDirection
            ?? ((bodyDirection == "rtl" && !verticalWriting) ? "rtl" : nil)
        let spineDirectionAttribute = resolvedPageProgressionDirection.map { #" page-progression-direction="\#($0)""# } ?? ""

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">urn:uuid:4b8bf82b-3c4f-4db4-96c8-7d3568fa0f77</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:language>\(languageCode)</dc:language>
            <dc:creator>\(creator)</dc:creator>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="chapter2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine\(spineDirectionAttribute)>
            <itemref idref="chapter1"/>
            <itemref idref="chapter2"/>
          </spine>
        </package>
        """.write(
            to: oebpsURL.appendingPathComponent("content.opf"),
            atomically: true,
            encoding: .utf8
        )

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="\(languageCode)">
          <head><title>目次</title></head>
          <body\(bodyDirection.map { #" dir="\#($0)""# } ?? "")>
            <nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
              <ol>
                <li><a href="chapter1.xhtml">\(chapterTitles.0)</a></li>
                <li><a href="chapter2.xhtml">\(chapterTitles.1)</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """.write(
            to: oebpsURL.appendingPathComponent("nav.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        try chapterHTML(
            title: chapterTitles.0,
            paragraphs: chapterParagraphs.0,
            verticalWriting: verticalWriting,
            languageCode: languageCode,
            bodyDirection: bodyDirection,
            additionalCSS: additionalCSS
        ).write(
            to: oebpsURL.appendingPathComponent("chapter1.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        try chapterHTML(
            title: chapterTitles.1,
            paragraphs: chapterParagraphs.1,
            verticalWriting: verticalWriting,
            languageCode: languageCode,
            bodyDirection: bodyDirection,
            additionalCSS: additionalCSS
        ).write(
            to: oebpsURL.appendingPathComponent("chapter2.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        let epubURL = rootURL.appendingPathComponent("generated-smoke.epub")
        let storedMimetypeResult = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-X0", epubURL.path, "mimetype"],
            currentDirectoryURL: rootURL,
            timeout: 30
        )
        XCTAssertEqual(storedMimetypeResult.exitCode, 0, storedMimetypeResult.combinedOutput)

        let archiveResult = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-Xr9D", epubURL.path, "META-INF", "OEBPS"],
            currentDirectoryURL: rootURL,
            timeout: 30
        )
        XCTAssertEqual(archiveResult.exitCode, 0, archiveResult.combinedOutput)

        return epubURL
    }

    private func chapterHTML(
        title: String,
        paragraphs: [String],
        verticalWriting: Bool,
        languageCode: String,
        bodyDirection: String?,
        additionalCSS: String?
    ) -> String {
        let body = paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")
        var styleRules: [String] = []
        if verticalWriting {
            styleRules.append(
                """
                html, body, section {
                  writing-mode: vertical-rl;
                  -epub-writing-mode: vertical-rl;
                }
                body {
                  line-height: 1.8;
                }
                """
            )
        }
        if let additionalCSS, !additionalCSS.isEmpty {
            styleRules.append(additionalCSS)
        }
        let styleBlock = styleRules.isEmpty
            ? ""
            : "<style>\n\(styleRules.joined(separator: "\n"))\n</style>"
        let dirAttribute = bodyDirection.map { #" dir="\#($0)""# } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="\(languageCode)">
          <head>
            <title>\(title)</title>
            <meta charset="utf-8" />
            \(styleBlock)
          </head>
          <body\(dirAttribute)>
            <section>
              <h1>\(title)</h1>
              \(body)
            </section>
          </body>
        </html>
        """
    }

    private func makeLongChapterParagraphs() -> [String] {
        let seedParagraphs = [
            "ある日の暮方の事である。ひとりの下人が、羅生門の下で雨やみを待っていた。広い門の下には、この男のほかに誰もいない。ただ、所々丹塗の剥げた大きな円柱に、蟋蟀が一匹とまっている。",
            "下人は、七段ある石段のいちばん上の段に洗いざらした紺の襖の尻を据えて、右の頬に出来た大きな面皰を気にしながら、ぼんやり、雨の降るのを眺めていた。作者はさっき、下人が雨やみを待っていたと書いた。",
            "しかし下人は、雨がやんでも、格別どうしようという当てはない。ふだんなら、もちろん、主人の家へ帰るべきはずである。ところがその主人からは、四、五日前に暇を出された。",
            "元来この下人のいた主人は、京の都が衰微するのにしたがって、いわばこの下人の運命までもが押し流されていくような時代のうねりの中にいた。彼はその行く末を、自分でも持て余していた。"
        ]

        let amplification = "同じ章の中で複数のネイティブページにまたがることを確認するため、文章量を意図的に増やしている。さらに同一段落の中で視覚的な折り返しとページ送りの両方が発生するように、補助文を繰り返し追加している。"

        return (0..<120).map { index in
            let base = seedParagraphs[index % seedParagraphs.count]
            return "\(base) 追補\(index + 1)。\(amplification)\(amplification)"
        }
    }

    private func assertOutputContains(_ pattern: String, in output: String, line: UInt = #line) {
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let matchFound = regex?.firstMatch(in: output, range: range) != nil
        XCTAssertTrue(matchFound, "Missing pattern: \(pattern)\n\(output)", line: line)
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lock = NSLock()
        var capturedData = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            capturedData.append(chunk)
            lock.unlock()
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            XCTFail("Timed out running \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))")
            throw NSError(domain: "EbookRendererHarnessSmokeTests", code: 1)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        let trailingData = pipe.fileHandleForReading.readDataToEndOfFile()
        if !trailingData.isEmpty {
            lock.lock()
            capturedData.append(trailingData)
            lock.unlock()
        }
        lock.lock()
        let output = String(decoding: capturedData, as: UTF8.self)
        lock.unlock()
        return ProcessResult(exitCode: Int(process.terminationStatus), combinedOutput: output)
    }
}

private struct ProcessResult {
    let exitCode: Int
    let combinedOutput: String
}
