import Foundation
import RealmSwift
import LakeKit
import RealmSwiftGaps
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock

fileprivate func makeArticleReadingProgressCompoundKey(url: URL) -> String {
    return String(format: "%02X", stableHash(url.absoluteString))
}

public class ArticleReadingProgress: ReadingSession {
    @Persisted public var sentenceIdentifiersRead: List<String>

    /// Exact retained reading lifetime selected by Common's source-authority
    /// layer. Nil is the legacy/unversioned lifetime. Lake stores the pointer
    /// but does not interpret, rotate, or synchronize authority on its own.
    @Persisted public var readAuthorityEpochID: String?

    // Web only, not for ebooks
    @Persisted public var articleSentenceCount: Int?
    @Persisted public var scrollPositionSentenceIdentifier: String?

    // For ebooks
    @Persisted public var fractionalCompletion: Float?
    @Persisted public var ebookCFI: String?

    // Cached difficulty snapshot for time-estimation heuristics
    @Persisted public var totalSegmentCount: Int = 0
    @Persisted public var unknownSegmentCount: Int = 0
    @Persisted public var learningSegmentCount: Int = 0
    @Persisted public var familiarSegmentCount: Int = 0
    @Persisted public var knownSegmentCount: Int = 0
    @Persisted public var difficultySnapshotUpdatedAt: Date?
    @Persisted public var wordIDsUnknownWhenRead: MutableSet<Int>

    // When true, exclude from Continue Reading lists
    @Persisted public var hideFromContinueReading: Bool = false

    public static func makePrimaryKey(url: URL) -> String {
        return makeArticleReadingProgressCompoundKey(url: url)
    }
}
