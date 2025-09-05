import SwiftUI
import RealmSwift
import FilePicker
import RealmSwiftGaps
import SwiftUtilities
import Combine

let libraryCategoriesQueue = DispatchQueue(label: "LibraryCategories")

@MainActor
class LibraryCategoriesViewModel: ObservableObject {
    @Published var userLibraryCategories: [FeedCategory]? = nil
    @Published var editorsPicksLibraryCategories: [FeedCategory]? = nil
    @Published var archivedCategories: [FeedCategory]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    @Published var libraryConfiguration: LibraryConfiguration?
    
    init() {
        Task { @RealmBackgroundActor [weak self] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
            
            realm.objects(FeedCategory.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryCategoriesQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    private func refreshData() {
        Task { @RealmBackgroundActor in
            let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
            let libraryConfigurationID = libraryConfiguration.id
            
            try await { @MainActor [weak self] in
                guard let self else { return }
                let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                
                guard let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID) else { return }
                self.libraryConfiguration = libraryConfiguration
                let categories = Array(libraryConfiguration.getCategories() ?? [])
                self.userLibraryCategories = categories.filter { $0.opmlURL == nil }
                self.editorsPicksLibraryCategories = categories.filter { $0.opmlURL != nil }
                
                let activeCategoryIDs = libraryConfiguration.getActiveCategories()?.map { $0.id } ?? []
                self.archivedCategories = Array(realm.objects(FeedCategory.self).where { ($0.isArchived || !$0.id.in(activeCategoryIDs)) && !$0.isDeleted })
            }()
        }
    }
    
    func deletionTitle(category: FeedCategory) -> String {
        if category.isArchived {
            return "Delete"
        }
        return "Archive"
    }
    
    func showDeleteButton(category: FeedCategory) -> Bool {
        return category.isUserEditable && !category.isDeleted
    }
    
    func showRestoreButton(category: FeedCategory) -> Bool {
        return category.isUserEditable && category.isArchived
    }
    
    @MainActor
    func deleteCategory(_ category: FeedCategory) async throws {
        let ref = ThreadSafeReference(to: category)
        async let task = { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.deleteCategory(category)
        }()
        try await task
    }
    
    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        let ref = ThreadSafeReference(to: category)
        async let task = { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.restoreCategory(category)
        }()
        try await task
    }
    
    @MainActor
    func deleteCategory(at offsets: IndexSet) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            guard let categories = libraryConfiguration.getCategories() else { return }
            for offset in offsets {
                let category = categories[offset]
                guard category.isUserEditable else { continue }
                let ref = ThreadSafeReference(to: category)
                try await Task { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                    guard let category = realm.resolve(ref) else { return }
                    try await LibraryDataManager.shared.deleteCategory(category)
                }.value
            }
        }
    }
    
    @MainActor
    func moveCategories(fromOffsets: IndexSet, toOffset: Int) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { _, libraryConfiguration in
                libraryConfiguration.categoryIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}
