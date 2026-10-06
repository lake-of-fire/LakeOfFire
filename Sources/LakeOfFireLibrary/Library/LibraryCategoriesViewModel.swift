import SwiftUI
import RealmSwift
import FilePicker
import RealmSwiftGaps
import SwiftUtilities
import Combine
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

let libraryCategoriesQueue = DispatchQueue(label: "LibraryCategories")

@MainActor
class LibraryCategoriesViewModel: ObservableObject {
    let realmConfiguration: Realm.Configuration

    @Published var userLibraryCategories: [FeedCategory]? = nil
    @Published var editorsPicksLibraryCategories: [FeedCategory]? = nil
    @Published var archivedCategories: [FeedCategory]? = nil

    nonisolated(unsafe) private var cancellables = Set<AnyCancellable>()

    @Published var libraryConfiguration: LibraryConfiguration?

    init(
        observesRealm: Bool = true,
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) {
        self.realmConfiguration = realmConfiguration
        guard observesRealm else { return }

        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: realmConfiguration
            )

            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(
                    for: .seconds(0.3),
                    scheduler: libraryDataQueue
                )
                .sink(
                    receiveCompletion: { @Sendable _ in },
                    receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.refreshData()
                        }
                    }
                )
                .store(in: &self.cancellables)

            realm.objects(FeedCategory.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(
                    for: .seconds(0.3),
                    scheduler: libraryCategoriesQueue
                )
                .sink(
                    receiveCompletion: { @Sendable _ in },
                    receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.refreshData()
                        }
                    }
                )
                .store(in: &self.cancellables)
        }
    }

    @discardableResult
    func refreshData() -> Task<Void, Error> {
        Task { @RealmBackgroundActor [realmConfiguration] in
            let libraryConfiguration =
                try await LibraryConfiguration.getConsolidatedOrCreate(
                    realmConfiguration: realmConfiguration
                )
            let configurationID = libraryConfiguration.id

            try await { @MainActor [weak self] in
                guard let self else { return }
                let realm = try await Realm.open(configuration: realmConfiguration)
                guard let libraryConfiguration = realm.object(
                    ofType: LibraryConfiguration.self,
                    forPrimaryKey: configurationID
                ) else {
                    return
                }

                self.libraryConfiguration = libraryConfiguration
                let categories = Array(
                    libraryConfiguration.getCategories() ?? []
                )
                self.userLibraryCategories = categories.filter {
                    $0.opmlURL == nil
                }
                self.editorsPicksLibraryCategories = categories.filter {
                    $0.opmlURL != nil
                }

                let activeCategoryIDs =
                    libraryConfiguration.getActiveCategories()?.map(\.id) ?? []
                self.archivedCategories = Array(
                    realm.objects(FeedCategory.self).where {
                        ($0.isArchived || !$0.id.in(activeCategoryIDs))
                            && !$0.isDeleted
                    }
                )
            }()
        }
    }

    func deletionTitle(category: FeedCategory) -> String {
        category.isArchived ? "Delete" : "Archive"
    }

    func showDeleteButton(category: FeedCategory) -> Bool {
        category.isUserEditable && !category.isDeleted
    }

    func showRestoreButton(category: FeedCategory) -> Bool {
        category.isUserEditable && category.isArchived
    }

    @MainActor
    func deleteCategory(_ category: FeedCategory) async throws {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.deleteCategory(
                categoryID: category.id,
                realmConfiguration: realmConfiguration
            )
        }.value
    }

    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.restoreCategory(
                categoryID: category.id,
                realmConfiguration: realmConfiguration
            )
        }.value
    }

    @MainActor
    func createCategory() async throws -> UUID {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.createEmptyCategory(
                addToLibrary: true,
                realmConfiguration: realmConfiguration
            )
        }.value
    }

    @MainActor
    @discardableResult
    func deleteCategory(at offsets: IndexSet) -> Task<Void, Error> {
        let categories = userLibraryCategories ?? []
        let ids = offsets.compactMap { index -> UUID? in
            guard categories.indices.contains(index),
                  categories[index].isUserEditable else {
                return nil
            }
            return categories[index].id
        }
        return Task { @MainActor in
            for categoryID in ids {
                try await Task { @RealmBackgroundActor [realmConfiguration] in
                    try await LibraryDataManager.shared.deleteCategory(
                        categoryID: categoryID,
                        realmConfiguration: realmConfiguration
                    )
                }.value
            }
        }
    }

    @MainActor
    @discardableResult
    func moveCategories(
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> Task<Void, Error>? {
        guard let libraryConfiguration,
              let visibleCategories = userLibraryCategories else {
            return nil
        }
        let originalIDs = Array(libraryConfiguration.categoryIDs)
        let visibleIDs = visibleCategories.map(\.id)
        guard !visibleIDs.isEmpty,
              Set(visibleIDs).count == visibleIDs.count,
              fromOffsets.allSatisfy(visibleIDs.indices.contains),
              fromOffsets.allSatisfy {
                  visibleCategories[$0].isUserEditable
              },
              visibleIDs.indices.contains(toOffset)
                || toOffset == visibleIDs.endIndex else {
            return nil
        }

        var reorderedIDs = visibleIDs
        reorderedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard reorderedIDs != visibleIDs else { return nil }

        let configurationID = libraryConfiguration.id
        let configurationCreatedAt = libraryConfiguration.createdAt
        return Task { @MainActor in
            try await Task { @RealmBackgroundActor [realmConfiguration] in
                let realm =
                    try await RealmBackgroundActor.shared.cachedRealm(
                        for: realmConfiguration
                    )
                try await realm.asyncWrite {
                    guard let currentConfiguration = realm.object(
                        ofType: LibraryConfiguration.self,
                        forPrimaryKey: configurationID
                    ),
                    !currentConfiguration.isDeleted,
                    currentConfiguration.createdAt == configurationCreatedAt,
                    Array(currentConfiguration.categoryIDs) == originalIDs else {
                        return
                    }

                    let visibleIDSet = Set(visibleIDs)
                    let currentVisibleIDs = originalIDs.compactMap {
                        categoryID -> UUID? in
                        guard visibleIDSet.contains(categoryID),
                              let category = realm.object(
                                ofType: FeedCategory.self,
                                forPrimaryKey: categoryID
                              ),
                              !category.isDeleted,
                              category.isUserEditable else {
                            return nil
                        }
                        return categoryID
                    }
                    guard currentVisibleIDs == visibleIDs,
                          reorderedIDs.count == currentVisibleIDs.count,
                          Set(reorderedIDs) == Set(currentVisibleIDs) else {
                        return
                    }

                    var nextRawIDs = originalIDs
                    var reorderedIndex = 0
                    for index in nextRawIDs.indices
                        where visibleIDSet.contains(nextRawIDs[index]) {
                        guard reorderedIndex < reorderedIDs.count else { return }
                        nextRawIDs[index] = reorderedIDs[reorderedIndex]
                        reorderedIndex += 1
                    }
                    guard reorderedIndex == reorderedIDs.count,
                          nextRawIDs.count == originalIDs.count,
                          nextRawIDs != originalIDs else {
                        return
                    }

                    currentConfiguration.categoryIDs.removeAll()
                    currentConfiguration.categoryIDs.append(
                        objectsIn: nextRawIDs
                    )
                    currentConfiguration.refreshChangeMetadata(
                        explicitlyModified: true
                    )
                }
            }.value
        }
    }
}
