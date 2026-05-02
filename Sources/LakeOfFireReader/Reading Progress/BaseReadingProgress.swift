import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeKit
import BigSyncKit
import LakeOfFireCore
import LakeOfFireAdblock

public let trivialReadingSessionAutoDeleteThreshold: TimeInterval = 2

public protocol ReadingProgressProtocol: Object, ObjectKeyIdentifiable {
    var id: String { get }
    var normalizedDate: Date { get set }
    var isDeleted: Bool { get set }

    var wordsRead: Int { get }
    var uniqueWordsLookedUp: Int { get }
    var trackedKanjiIDsRead: MutableSet<String> { get }
}

open class BaseReadingProgress: Object, ObjectKeyIdentifiable, ReadingProgressProtocol, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var id = UUID().uuidString

    @Persisted public var normalizedDate = Date()

    @Persisted public var incrementalActiveReadingBeganAt: Date?
    @Persisted public var activeDuration: TimeInterval = 0

    /// Counts unique "segments", not unique words, in articles.
    @Persisted public var wordsRead = 0
    @Persisted public var charactersRead = 0
    @Persisted public var readSegmentIdentifiers: MutableSet<String>

    @Persisted public var segmentsUnknownWhenRead: Int = 0
    @Persisted public var segmentsLearningWhenRead: Int = 0
    @Persisted public var segmentsFamiliarWhenRead: Int = 0
    @Persisted public var segmentsKnownWhenRead: Int = 0
    @Persisted public var charactersUnknownWhenRead: Int = 0
    @Persisted public var charactersLearningWhenRead: Int = 0
    @Persisted public var charactersFamiliarWhenRead: Int = 0
    @Persisted public var charactersKnownWhenRead: Int = 0

    @Persisted public var uniqueUnreadUnknownWordsRead = 0
    @Persisted public var uniqueUnknownWordsRead = 0
    @Persisted public var uniqueLearningWordsRead = 0
    @Persisted public var uniqueFamiliarWordsRead = 0

    @Persisted public var trackedKanjiIDsRead: MutableSet<String>
    @Persisted public var trackedWordIDsRead: MutableSet<Int>

    @Persisted public var flashcardsCreated = 0
    @Persisted public var trackedWordIDsWithFlashcardsCreated: MutableSet<Int>
    @Persisted public var jmdictIDsMarkedAsKnown: List<Int>

    @Persisted public var uniqueWordsLookedUp = 0
    // TODO: Unused, remove?
    @Persisted public var trackedWordIDsLookedUp: MutableSet<Int>
    @Persisted public var webpagesCompleted = 0
    @Persisted public var bookChaptersCompleted = 0
    @Persisted public var completedContentKeys: MutableSet<String>

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
