import Foundation
import RealmSwift
import RealmSwiftGaps

public class HistoryRecord: Bookmark {
    @Persisted public var lastVisitedAt = Date()
    
    @Persisted public var bookmarkID: String?
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
}

extension HistoryRecord: DeletableReaderContent {
    public var deleteActionTitle: String {
        "Remove from History…"
    }
}

extension DeletableReaderContent {
    @MainActor
    public func delete() async throws {
        guard let contentRef = ReaderContentLoader.ContentReference(content: self) else { return }
        try await { @RealmBackgroundActor in
            guard let content = try await contentRef.resolveOnBackgroundActor() else { return }
            await content.realm?.asyncRefresh()
            try await content.realm?.asyncWrite {
                //            for videoStatus in realm.objects(VideoS)
                content.isDeleted = true
                content.modifiedAt = Date()
            }
        }()
    }
    
//    @MainActor
//    public func delete() async throws {
//        guard let content = try await ReaderContentLoader.fromMainActor(content: self) as? Self, let realm = content.realm else { return }
//        await realm.asyncRefresh()
//        try await realm.asyncWrite {
//            content.isDeleted = true
//            content.modifiedAt = Date()
//        }
//    }
}

//public extension HistoryRecord {
//  /// A way to compare `Bool`s.
//  ///
//  /// Note: `false` is "less than" `true`.
//  enum Comparable: CaseIterable, Swift.Comparable {
//    case `false`, `true`
//  }
//
//  /// Make a `Bool` `Comparable`, with `false` being "less than" `true`.
//  var comparable: Comparable { .init(booleanLiteral: self) }
//}

//public struct OptionalHistoryRecordBookmarkComparator: SortComparator {
//    public var order: SortOrder = .forward
//
//    public func compare(_ lhs: HistoryRecord?, _ rhs: HistoryRecord?) -> ComparisonResult {
//        let result: ComparisonResult
//        switch (lhs?.bookmark, rhs?.bookmark) {
//        case (nil, nil): result = .orderedSame
//        case (.some, nil): result = .orderedDescending
//        case (nil, .some): result = .orderedAscending
//        case let (lhs?, rhs?):
//            result = lhs.createdAt.compare(rhs.createdAt)
//        }
//        return order == .forward ? result : result.reversed
//    }
//
//    public init(order: SortOrder = .forward) {
//        self.order = order
//    }
//}
//
//fileprivate extension ComparisonResult {
//    var reversed: ComparisonResult {
//        switch self {
//        case .orderedAscending: return .orderedDescending
//        case .orderedSame: return .orderedSame
//        case .orderedDescending: return .orderedAscending
//        }
//    }
//}
