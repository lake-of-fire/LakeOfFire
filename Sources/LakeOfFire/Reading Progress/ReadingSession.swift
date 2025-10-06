import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealmSwift
import LakeKit
import RealmSwiftGaps

/// Corresponds to one active session of reading a particular article. Reading an article could span multiple sessions.
public class ReadingSession: BaseReadingProgress {
    // Usually we can match the article via the history record,
    // but this is here for potential future use in case history gets cleared.
    // Won't cover all kinds of reading material.
    @Persisted public var url: URL
    @Persisted public var title: String?
    @Persisted public var imageUrl: String?
    @Persisted public var htmlContentHash: String?

    @Persisted public var startedAt = Date()
    @Persisted public var endedAt: Date?
    @Persisted public var articleMarkedAsFinished = false
    @Persisted public var hasContributedToPaceSummary = false

    public var worthDisplayingSummaryToUser: Bool {
        return wordsRead > 0
    }

    public var isEmpty: Bool {
        return !articleMarkedAsFinished && wordsRead == 0
    }
}
