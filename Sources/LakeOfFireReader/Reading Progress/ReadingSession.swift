import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealmSwift
import LakeKit
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock

/// Corresponds to a per-day active session of reading a particular article.
/// Sessions are partitioned at the normalized start of day (05:00 local time by default),
/// so a single article can generate multiple sessions across calendar days while
/// continuing to allow multiple sessions within the same normalized day when needed.
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
