import XCTest
import SwiftReadability
@testable import LakeOfFireContent

final class WikipediaReadabilityRegressionTests: XCTestCase {
    private static let expectedCollapsedSectionMarkers = [
        "Venture incubation",
        "Other activities",
        "Controversies",
    ]

    private static let expectedCollapsedSectionBodyMarkers = [
        "Throughout 2020, Mozilla ran Mozilla Builders",
        "Mozilla VR is a team focused on bringing tools, specifications, and standards to the open Web.",
        "In February 2014, Mozilla released Directory Tiles",
        "On December 15, 2017, Mozilla installed an add-on in all Firefox Quantum browsers, titled \"Looking Glass,\"",
    ]

    private static let sourcePageURL = URL(string: "https://en.wikipedia.org/wiki/Mozilla?useskin=minerva")!
    private static let classesToPreserve = [
        "caption",
        "emoji",
        "hidden",
        "invisible",
        "sr-only",
        "visually-hidden",
        "visuallyhidden",
        "wp-caption",
        "wp-caption-text",
        "wp-smiley",
    ]

    private func loadFixtureHTML() throws -> String {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "mozilla-wikipedia-minerva",
                withExtension: "html",
                subdirectory: "Fixtures/Readability"
            ) ?? Bundle.module.url(
                forResource: "mozilla-wikipedia-minerva",
                withExtension: "html"
            )
        )
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    private func stripExecutableScripts(from html: String) -> String {
        html.replacingOccurrences(
            of: #"(?is)<script\b[^>]*>.*?</script>"#,
            with: "",
            options: .regularExpression
        )
    }

    private func collapseWhitespace(in text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseFixtureWithSwiftReadability(_ html: String) throws -> String {
        let sanitizedHTML = stripExecutableScripts(from: html)
        let parser = SwiftReadability.Readability(
            html: sanitizedHTML,
            url: Self.sourcePageURL,
            options: ReadabilityOptions(
                charThreshold: 500,
                classesToPreserve: Self.classesToPreserve
            )
        )
        let result = try XCTUnwrap(parser.parse())
        return result.content
    }

    func testMozillaWikipediaFixtureContainsCollapsedSectionMarkers() throws {
        let html = try loadFixtureHTML()

        for marker in Self.expectedCollapsedSectionMarkers {
            XCTAssertTrue(
                html.contains(marker),
                "Fixture no longer contains expected Wikipedia section marker '\(marker)'"
            )
        }
    }

    func testSwiftReadabilityKeepsCollapsedWikipediaSectionBodyText() throws {
        let html = try loadFixtureHTML()
        let outputHTML = try parseFixtureWithSwiftReadability(html)
        let normalizedOutputHTML = collapseWhitespace(in: outputHTML)

        for marker in Self.expectedCollapsedSectionBodyMarkers {
            XCTAssertTrue(
                normalizedOutputHTML.contains(marker),
                "SwiftReadability dropped Wikimedia collapsed section body text '\(marker)'"
            )
        }
    }
}
