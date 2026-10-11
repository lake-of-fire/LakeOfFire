import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

enum LibraryCategoryField: Hashable, Sendable {
    case title, imageURL
}

enum LibraryCategoryFieldEdit: Equatable, Sendable {
    case title(String), imageURL(String)

    var field: LibraryCategoryField {
        switch self {
        case .title: return .title
        case .imageURL: return .imageURL
        }
    }

    @RealmBackgroundActor
    func apply(to category: FeedCategory) -> Bool {
        switch self {
        case .title(let value):
            guard category.title != value else { return false }
            category.title = value
        case .imageURL(let value):
            guard let url = URL(string: value.isEmpty ? "about:blank" : value),
                  category.backgroundImageUrl != url else { return false }
            category.backgroundImageUrl = url
        }
        return true
    }
}

struct LibraryCategoryFieldOwner: Sendable {
    let categoryID: UUID
    let createdAt: Date
    let realmConfiguration: Realm.Configuration

    @MainActor
    init?(category: FeedCategory, realmConfiguration: Realm.Configuration? = nil) {
        guard !category.isInvalidated else { return nil }
        categoryID = category.id
        createdAt = category.createdAt
        self.realmConfiguration = category.realm?.configuration ?? realmConfiguration ?? LibraryDataManager.realmConfiguration
    }

    @RealmBackgroundActor
    func resolve(in realm: Realm) -> FeedCategory? {
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              category.createdAt == createdAt, !category.isDeleted, category.isUserEditable else { return nil }
        return category
    }
}

struct LibraryCategoryFieldIdentity: Hashable, Sendable {
    let categoryID: UUID
    let createdAt: Date
    let storage: String
    let encryptionKey: Data?
    let schemaVersion: UInt64

    init(owner: LibraryCategoryFieldOwner) {
        categoryID = owner.categoryID
        createdAt = owner.createdAt
        let configuration = owner.realmConfiguration
        storage = configuration.inMemoryIdentifier.map { "memory:" + $0 }
            ?? configuration.fileURL.map { "file:" + $0.resolvingSymlinksInPath().standardizedFileURL.path }
            ?? "default"
        encryptionKey = configuration.encryptionKey
        schemaVersion = configuration.schemaVersion
    }
}

/// Match main's script editor: current input admits the synchronous final mutation.
/// This is transient per-field ordering, not a persisted conflict/clock mechanism.
final class LibraryCategoryFieldWriteOrdering: @unchecked Sendable {
    private final class WeakOrdering {
        weak var value: LibraryCategoryFieldWriteOrdering?
        init(_ value: LibraryCategoryFieldWriteOrdering) { self.value = value }
    }
    @MainActor private static var orderings: [LibraryCategoryFieldIdentity: WeakOrdering] = [:]
    private let lock = NSLock()
    private var intents: [LibraryCategoryField: UUID] = [:]

    @MainActor
    static func shared(identity: LibraryCategoryFieldIdentity) -> LibraryCategoryFieldWriteOrdering {
        orderings = orderings.filter { $0.value.value != nil }
        if let existing = orderings[identity]?.value { return existing }
        let ordering = LibraryCategoryFieldWriteOrdering()
        orderings[identity] = WeakOrdering(ordering)
        return ordering
    }

    func issueIntent(field: LibraryCategoryField) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let intent = UUID()
        intents[field] = intent
        return intent
    }

    func withAdmission(field: LibraryCategoryField, intent: UUID, apply: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard intents[field] == intent else { return }
        apply()
    }
}

struct LibraryCategoryFieldCommand: Sendable {
    let owner: LibraryCategoryFieldOwner
    let edit: LibraryCategoryFieldEdit
    let intent: UUID
    let ordering: LibraryCategoryFieldWriteOrdering

    @RealmBackgroundActor
    func write(beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: owner.realmConfiguration)
        try await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard let category = owner.resolve(in: realm) else { return }
            ordering.withAdmission(field: edit.field, intent: intent) {
                guard edit.apply(to: category) else { return }
                category.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}
