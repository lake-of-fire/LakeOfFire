import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeKit
import BigSyncKit

public protocol ReadingProgressProtocol: Object, ObjectKeyIdentifiable {
    var id: String { get }
    var normalizedDate: Date { get set }
    var isDeleted: Bool { get set }

    var wordsRead: Int { get }
    var uniqueWordsLookedUp: Int { get }
}

open class BaseReadingProgress: Object, ObjectKeyIdentifiable, ReadingProgressProtocol, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var id = UUID().uuidString

    @Persisted public var normalizedDate = Date()

    @Persisted public var incrementalActiveReadingBeganAt: Date?
    @Persisted public var activeDuration: TimeInterval = 0

    /// Counts unique "segments", not unique words, in articles.
    @Persisted public var wordsRead = 0
    @Persisted public var readSegmentIdentifiers: MutableSet<String>

    @Persisted public var uniqueUnreadUnknownWordsRead = 0
    @Persisted public var uniqueUnknownWordsRead = 0
    @Persisted public var uniqueLearningWordsRead = 0
    @Persisted public var uniqueFamiliarWordsRead = 0

    // TODO: Also track kanjiRead in session
    @Persisted public var trackedWordIDsRead: MutableSet<Int>

    @Persisted public var flashcardsCreated = 0
    @Persisted public var trackedWordIDsWithFlashcardsCreated: MutableSet<Int>
    @Persisted public var jmdictIDsMarkedAsKnown: List<Int>

    @Persisted public var uniqueWordsLookedUp = 0
    // TODO: Unused, remove?
    @Persisted public var trackedWordIDsLookedUp: MutableSet<Int>

    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false

    public override class func primaryKey() -> String? {
        return "id"
    }

    public var humanReadableActiveDuration: String {
        let formatter = DateComponentsFormatter()
        if activeDuration < 60 {
            formatter.allowedUnits = [.second]
        } else {
            formatter.allowedUnits = [.hour, .minute]
        }
        formatter.unitsStyle = .full
        return formatter.string(from: activeDuration) ?? "\(round(activeDuration.rounded())) seconds"
    }
}
