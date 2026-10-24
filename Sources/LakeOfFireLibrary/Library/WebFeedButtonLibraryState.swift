import Combine
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeOfFireContent

struct LibraryWebFeedCategorySnapshot: Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let title: String

    var destination: LibraryFeedCreationDestination {
        .category(id: id, createdAt: createdAt)
    }
}

struct LibraryWebFeedAddChoice: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case category(UUID)
        case newUserCategory
    }

    let id: ID
    let title: String
    let destination: LibraryFeedCreationDestination

    static func choices(for categories: [LibraryWebFeedCategorySnapshot]?) -> [Self] {
        guard let categories, !categories.isEmpty else {
            return [.init(id: .newUserCategory, title: "Add Feed to My Library", destination: .newUserCategory)]
        }
        return categories.map {
            .init(id: .category($0.id),
                  title: "Add Feed to \($0.title.isEmpty ? "Untitled" : $0.title)",
                  destination: $0.destination)
        }
    }
}

struct LibraryWebFeedSelection: Equatable, Sendable {
    let feedID: UUID
    let feedCreatedAt: Date
    let rssURL: URL
    let categoryID: UUID
    let categoryCreatedAt: Date
}

private struct LibraryWebFeedSnapshot {
    var generation: UUID?
    var categories: [LibraryWebFeedCategorySnapshot]?
    var feedsByRSSURL: [URL: LibraryWebFeedSelection] = [:]
    var hasFailed = false
}

private struct LibraryWebFeedConfigurationIdentity: Sendable {
    let id: UUID
    let createdAt: Date
}

private enum LibraryWebFeedObservationError: Error {
    case retiredLibrary
    case uncommittedRealm
}

/// Each Library model owns its state and original storage admission. Only value
/// snapshots leave the state; every action resolves again on its MainActor Realm.
@MainActor
final class WebFeedButtonLibraryState: ObservableObject {
    @Published private var snapshot = LibraryWebFeedSnapshot()

    private let realmConfiguration: Realm.Configuration
    private let storageAdmission: RealmStorageAdmission
    private let beforeRefresh: (@MainActor @Sendable () async throws -> Void)?
    private let beforePublication: (@MainActor @Sendable () async throws -> Void)?
    private var presentations = Set<UUID>()
    private var generation: UUID?
    private var refreshID: UUID?
    private var realm: Realm?
    private var notificationTokens: [NotificationToken] = []
    private var changes = PassthroughSubject<Void, Never>()
    private var changeSubscription: AnyCancellable?
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    init(
        realmConfiguration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission,
        beforeRefresh: (@MainActor @Sendable () async throws -> Void)? = nil,
        beforePublication: (@MainActor @Sendable () async throws -> Void)? = nil
    ) {
        self.realmConfiguration = realmConfiguration
        self.storageAdmission = storageAdmission
        self.beforeRefresh = beforeRefresh
        self.beforePublication = beforePublication
    }

    var userCategories: [LibraryWebFeedCategorySnapshot]? {
        guard let generation, snapshot.generation == generation,
              isCurrentStorage else { return nil }
        return snapshot.categories
    }

    var hasFailed: Bool {
        generation == nil && snapshot.hasFailed
    }

    private var isCurrentStorage: Bool {
        storageAdmission.matchesCurrentStorageIdentity {
            RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
        }
    }

    /// Several mounted Reader buttons may share this model. One disappearance
    /// must not retire the subscriptions still used by another presentation.
    @discardableResult
    func beginObservation(for presentationID: UUID) -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        presentations.insert(presentationID)
        guard generation == nil else { return refreshID.flatMap { inFlight[$0] } }
        let generation = UUID()
        self.generation = generation
        let changes = PassthroughSubject<Void, Never>()
        self.changes = changes
        changeSubscription = changes
            .debounceLeadingTrailing(for: .seconds(0.1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.refresh(ifCurrent: generation)
                }
            }
        return refresh(ifCurrent: generation)
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard let presentationID = presentations.first, generation == nil else { return nil }
        return beginObservation(for: presentationID)
    }

    /// Retires publication synchronously and returns settlement for all admitted
    /// tasks. Tests and explicit owner retirement can await that actual work.
    @discardableResult
    func endObservation(for presentationID: UUID) -> Task<Void, Never>? {
        guard presentations.remove(presentationID) != nil,
              presentations.isEmpty else { return nil }
        return retireObservation(hasFailed: false)
    }

    func stopObservation() async {
        presentations.removeAll()
        await retireObservation(hasFailed: false).value
    }

    private func retireObservation(hasFailed: Bool) -> Task<Void, Never> {
        generation = nil
        refreshID = nil
        changeSubscription = nil
        notificationTokens.forEach { $0.invalidate() }
        notificationTokens.removeAll()
        realm = nil
        let pending = Array(inFlight.values)
        pending.forEach { $0.cancel() }
        snapshot = LibraryWebFeedSnapshot(hasFailed: hasFailed)
        return Task { @MainActor in
            for task in pending {
                await task.value
            }
        }
    }

    @discardableResult
    private func refresh(ifCurrent generation: UUID) -> Task<Void, Never>? {
        guard self.generation == generation, !presentations.isEmpty else { return nil }
        if let refreshID { inFlight[refreshID]?.cancel() }
        let requestID = UUID()
        refreshID = requestID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.inFlight.removeValue(forKey: requestID)
                if self.refreshID == requestID { self.refreshID = nil }
            }
            do {
                try self.checkCurrent(generation: generation, requestID: requestID)
                try await self.beforeRefresh?()
                try self.checkCurrent(generation: generation, requestID: requestID)
                let configuration = self.realmConfiguration
                let admission = self.storageAdmission
                // This admitted open owns a missing file before any convenience
                // singleton or MainActor Realm can create it independently.
                let library = try await { @RealmBackgroundActor in
                    try await RealmBackgroundActor.shared.prepareStorage(
                        for: configuration, storageAdmission: admission
                    )
                    let library = try await LibraryConfiguration.getConsolidatedOrCreate(
                        realmConfiguration: configuration, storageAdmission: admission
                    )
                    return LibraryWebFeedConfigurationIdentity(
                        id: library.id, createdAt: library.createdAt
                    )
                }()
                try self.checkCurrent(generation: generation, requestID: requestID)
                let realm: Realm
                if let currentRealm = self.realm {
                    realm = currentRealm
                } else {
                    realm = try await Realm.open(configuration: configuration)
                }
                try self.checkCurrent(generation: generation, requestID: requestID)
                guard !realm.isInWriteTransaction else {
                    throw LibraryWebFeedObservationError.uncommittedRealm
                }
                await realm.asyncRefresh()
                try await self.beforePublication?()
                try self.checkCurrent(generation: generation, requestID: requestID)
                // The hook and Realm refresh may suspend. Read authoritative
                // values on this actor only after current ownership is checked.
                guard !realm.isInWriteTransaction else {
                    throw LibraryWebFeedObservationError.uncommittedRealm
                }
                _ = realm.refresh()
                try self.checkCurrent(generation: generation, requestID: requestID)
                guard !realm.isInWriteTransaction else {
                    throw LibraryWebFeedObservationError.uncommittedRealm
                }
                guard let libraryConfiguration = realm.object(
                    ofType: LibraryConfiguration.self, forPrimaryKey: library.id
                ), !libraryConfiguration.isInvalidated,
                   !libraryConfiguration.isDeleted,
                   libraryConfiguration.createdAt == library.createdAt else {
                    throw LibraryWebFeedObservationError.retiredLibrary
                }

                var next = LibraryWebFeedSnapshot(generation: generation)
                next.categories = (libraryConfiguration.getActiveCategories() ?? [])
                    .filter { !$0.isInvalidated && !$0.isDeleted && $0.opmlURL == nil }
                    .map { LibraryWebFeedCategorySnapshot(
                        id: $0.id, createdAt: $0.createdAt, title: $0.title
                    ) }
                for feed in realm.objects(Feed.self).where({ !$0.isDeleted }) {
                    guard !feed.isInvalidated,
                          let categoryID = feed.categoryID,
                          let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                          !category.isInvalidated, !category.isDeleted,
                          next.feedsByRSSURL[feed.rssUrl] == nil else { continue }
                    next.feedsByRSSURL[feed.rssUrl] = LibraryWebFeedSelection(
                        feedID: feed.id, feedCreatedAt: feed.createdAt,
                        rssURL: feed.rssUrl, categoryID: categoryID,
                        categoryCreatedAt: category.createdAt
                    )
                }
                try self.checkCurrent(generation: generation, requestID: requestID)
                self.realm = realm
                if self.notificationTokens.isEmpty {
                    self.installObservers(in: realm, generation: generation)
                }
                self.snapshot = next
            } catch is CancellationError {
                // A newer refresh or retired presentation owns any next result.
                if self.generation == generation, self.refreshID == requestID {
                    _ = self.retireObservation(hasFailed: false)
                }
            } catch {
                guard self.generation == generation, self.refreshID == requestID else { return }
                _ = self.retireObservation(hasFailed: true)
                print("Failed to load web feed Library state: \(error)")
            }
        }
        inFlight[requestID] = task
        return task
    }

    private func checkCurrent(generation: UUID, requestID: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation, self.refreshID == requestID,
              !presentations.isEmpty else { throw CancellationError() }
        guard isCurrentStorage else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
    }

    private func installObservers(in realm: Realm, generation: UUID) {
        // This Realm was opened on MainActor. The SDK delivers these callbacks
        // on that Realm's actor; neither a Realm nor its rows crosses actors.
        notificationTokens = [
            realm.objects(LibraryConfiguration.self).observe { [weak self] change in
                if case .error(let error) = change {
                    self?.observationFailed(error, ifCurrent: generation)
                } else {
                    self?.observedChanges(ifCurrent: generation)
                }
            },
            realm.objects(Feed.self).where { !$0.isDeleted }.observe { [weak self] change in
                if case .error(let error) = change {
                    self?.observationFailed(error, ifCurrent: generation)
                } else {
                    self?.observedChanges(ifCurrent: generation)
                }
            },
            realm.objects(FeedCategory.self).observe { [weak self] change in
                if case .error(let error) = change {
                    self?.observationFailed(error, ifCurrent: generation)
                } else {
                    self?.observedChanges(ifCurrent: generation)
                }
            },
        ]
    }

    private func observedChanges(ifCurrent generation: UUID) {
        guard self.generation == generation, !presentations.isEmpty else { return }
        changes.send(())
    }

    private func observationFailed(_ error: Error, ifCurrent generation: UUID) {
        guard self.generation == generation else { return }
        _ = retireObservation(hasFailed: true)
        print("Failed to observe web feed Library state: \(error)")
    }

    func feed(matching rssURLs: [URL]) -> LibraryWebFeedSelection? {
        guard let generation, snapshot.generation == generation else { return nil }
        for url in rssURLs {
            guard let selection = snapshot.feedsByRSSURL[url],
                  resolve(selection) != nil else { continue }
            return selection
        }
        return nil
    }

    func resolve(_ selection: LibraryWebFeedSelection) -> Feed? {
        guard let generation, snapshot.generation == generation,
              !presentations.isEmpty, isCurrentStorage, let realm,
              !realm.isFrozen, !realm.isInWriteTransaction else { return nil }
        _ = realm.refresh()
        guard self.generation == generation, snapshot.generation == generation,
              isCurrentStorage, !realm.isInWriteTransaction,
              let feed = realm.object(ofType: Feed.self, forPrimaryKey: selection.feedID),
              !feed.isInvalidated, !feed.isFrozen, !feed.isDeleted,
              feed.createdAt == selection.feedCreatedAt, feed.rssUrl == selection.rssURL,
              feed.categoryID == selection.categoryID,
              let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: selection.categoryID),
              !category.isInvalidated, !category.isDeleted,
              category.createdAt == selection.categoryCreatedAt else { return nil }
        return feed
    }
}
