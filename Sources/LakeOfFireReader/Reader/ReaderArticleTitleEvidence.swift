import Foundation
import SwiftSoup
import SwiftUtilities

struct ReaderArticleTitleEvidence: Sendable {
    let heading: String
    let legacyFlattenedTitle: String?

    func replacement(for storedTitle: String) -> String? {
        let legacyTitleMatches = legacyFlattenedTitle.map { storedTitle.utf8.elementsEqual($0.utf8) } ?? false
        guard storedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || legacyTitleMatches else { return nil }
        return heading
    }
}

func readerArticleTitleEvidence(from html: String) -> ReaderArticleTitleEvidence? {
    guard let document = try? SwiftSoup.parse(html) else { return nil }
    let headings = [try? document.getElementById("reader-title"), try? document.getElementsByTag("h1").first()]
    for case let original? in headings {
        guard let detached = original.copy() as? SwiftSoup.Element,
              (try? detached.select("ruby rt, ruby rp, ruby rtc").remove()) != nil,
              let heading = normalizedArticleHeading(try? detached.text()) else { continue }

        let flattened = normalizedArticleHeading(try? original.text())
        let hasRubyReading = (try? original.select("ruby rt, ruby rtc").first()) != nil
        let legacyFlattenedTitle = hasRubyReading && flattened != heading ? flattened : nil
        return ReaderArticleTitleEvidence(heading: heading, legacyFlattenedTitle: legacyFlattenedTitle)
    }
    return nil
}

private func normalizedArticleHeading(_ raw: String?) -> String? {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed.truncate(36)
}
