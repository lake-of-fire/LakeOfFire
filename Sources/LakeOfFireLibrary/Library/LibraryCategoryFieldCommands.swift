import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

enum LibraryCategoryFieldMutationResult: Sendable, Equatable {
    case changed(changedAt: Date)
    case unchanged
    case unavailable
}

enum LibraryCategoryField: Sendable, Equatable {
    case title
    case backgroundImageURL
}

enum LibraryCategoryFieldCommand {
    nonisolated(unsafe) static var beforeWriteTestHook: (
        @Sendable (LibraryCategoryField, String) async throws -> Void
    )?

    @RealmBackgroundActor
    static func setTitle(
        _ title: String,
        categoryID: UUID,
        categoryCreatedAt: Date,
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> LibraryCategoryFieldMutationResult {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await beforeWriteTestHook?(.title, title)
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let category = realm.object(
                ofType: FeedCategory.self,
                forPrimaryKey: categoryID
            ), !category.isDeleted,
            category.createdAt == categoryCreatedAt,
            category.isUserEditable else {
                return .unavailable
            }
            guard category.title != title else { return .unchanged }
            category.title = title
            category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return .changed(changedAt: timestamp)
        }
    }

    @RealmBackgroundActor
    static func setBackgroundImageURL(
        _ backgroundImageURL: URL,
        categoryID: UUID,
        categoryCreatedAt: Date,
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> LibraryCategoryFieldMutationResult {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await beforeWriteTestHook?(
            .backgroundImageURL,
            backgroundImageURL.absoluteString
        )
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let category = realm.object(
                ofType: FeedCategory.self,
                forPrimaryKey: categoryID
            ), !category.isDeleted,
            category.createdAt == categoryCreatedAt,
            category.isUserEditable else {
                return .unavailable
            }
            guard category.backgroundImageUrl != backgroundImageURL else {
                return .unchanged
            }
            category.backgroundImageUrl = backgroundImageURL
            category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return .changed(changedAt: timestamp)
        }
    }
}
