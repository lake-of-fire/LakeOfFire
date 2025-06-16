import Foundation
import OPML
import RealmSwift
import BigSyncKit
import Combine
import SwiftUIWebView
import BackgroundAssets
import Collections
import SwiftUIDownloads
import RealmSwiftGaps

let libraryDataQueue = DispatchQueue(label: "LibraryDataQueue")

//extension URL: FailableCustomPersistable {
//    public typealias PersistedType = String
//
//    public init?(persistedValue: String) {
//        if persistedValue.isEmpty || URL(string: persistedValue) == nil {
//            self.init(string: "about:blank")
//        } else {
//            self.init(string: persistedValue)
//        }
//    }
//
//    public var persistableValue: String {
//        absoluteString
//    }
//
//    public static func _rlmDefaultValue() -> Self {
//        .init(string: "about:blank")!
//    }
//}

public class LibraryConfiguration: Object, UnownedSyncableObject, ChangeMetadataRecordable {
    public static var securityApplicationGroupIdentifier = ""
    public static var downloadstDirectoryName = "library-configuration"
    public static var opmlURLs = [URL]()

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var opmlLastImportedAt: Date?
    
    @Persisted public var categoryIDs: RealmSwift.List<UUID>
    @Persisted public var userScriptIDs: RealmSwift.List<UUID>
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    public lazy var systemScripts: [WebViewUserScript] = {
        return [
            Readability.shared.userScript,
            ReadabilityImagesUserScript.shared.userScript,
            ReaderConsoleLogsUserScript.shared.userScript,
//            ManabiReaderUserScript().userScript,
//            YoutubeAdBlockUserScript.userScript,
//            YoutubeAdSkipUserScript.userScript,
//            YoutubeCaptionsUserScript.userScript,
        ]
    }()
    
    public var needsSyncToAppServer: Bool {
        return false
    }
    
    public func getUserCategories() -> [FeedCategory]? {
        return getCategories()?.filter { $0.opmlURL == nil }
    }
    
    public func getActiveCategories() -> [FeedCategory]? {
        return getCategories()?.filter { !$0.isArchived }
    }

    @MainActor
    public var downloadables: Set<Downloadable> {
        guard !Self.securityApplicationGroupIdentifier.isEmpty else { fatalError("securityApplicationGroupIdentifier unset") }
        return Set(Self.opmlURLs.compactMap { url in
            if let downloadable = DownloadController.shared.assuredDownloads.first(where: { $0.url == url }) {
                return downloadable
            } else {
                return Downloadable(
                    name: "App Data (\(url.lastPathComponent))",
                    groupIdentifier: Self.securityApplicationGroupIdentifier,
                    parentDirectoryName: Self.downloadstDirectoryName,
                    downloadMirrors: [url])
            }
        })
    }
    
    public func getCategories(includingDeleted: Bool = false) -> [FeedCategory]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        let categories = categoryIDs.compactMap { realm.object(ofType: FeedCategory.self, forPrimaryKey: $0) }
        if includingDeleted {
            return categories.map { $0 }
        }
        return categories.filter { !$0.isDeleted }
    }
    
    public func getUserScripts() -> [UserScript]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return userScriptIDs.compactMap { realm.object(ofType: UserScript.self, forPrimaryKey: $0) } .filter { !$0.isDeleted }
    }

//    @available(macOS 13.0, iOS 16.1, *)
//    public func pendingBackgroundAssetDownloads() -> Set<BADownload> {
//        let downloadables = downloadables
//        Task.detached { @MainActor in
//            await DownloadController.shared.ensureDownloaded(downloadables)
//        }
//        return Set(downloadables.compactMap({ $0.backgroundAssetDownload(applicationGroupIdentifier: Self.securityApplicationGroupIdentifier)}))
//    }
    
    public func getActiveWebViewUserScripts() -> [WebViewUserScript]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return Array(getUserScripts()?.filter { !$0.isArchived }.compactMap { $0.getWebViewUserScript() } ?? [])
    }
//    
//    public static func get() throws -> LibraryConfiguration? {
//        let realm = try Realm(configuration: LibraryDataManager.realmConfiguration)
//        if let configuration = realm.objects(LibraryConfiguration.self).sorted(by: \.modifiedAt, ascending: true).first(where: { !$0.isDeleted }) {
//            return configuration
//        }
//        return nil
//    }
//    
//    @RealmBackgroundActor
//    public static func get() async throws -> LibraryConfiguration? {
//        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return nil }
//        if let configuration = realm.objects(LibraryConfiguration.self).sorted(by: \.modifiedAt, ascending: true).first(where: { !$0.isDeleted }) {
//            return configuration
//        }
//        return nil
//    }
//    
//    @MainActor
//    public static func getOnMain() async throws -> LibraryConfiguration? {
//        let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
//        if let configuration = realm.objects(LibraryConfiguration.self).sorted(by: \.modifiedAt, ascending: true).first(where: { !$0.isDeleted }) {
//            return configuration
//        }
//        return nil
//    }
    
    @RealmBackgroundActor
    public static func getConsolidatedOrCreate() async throws -> LibraryConfiguration {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) 
        
        // Take oldest as primary. Consolidate newer ones into it.
        let configurations = Array(realm.objects(LibraryConfiguration.self).where { !$0.isDeleted } .sorted(by: \.modifiedAt, ascending: true))
        if let primaryConfiguration = configurations.first {
            let otherConfigurations = configurations.dropFirst()
            
            // Remove archived or deleted categories
            let inactiveCategoryIDs = primaryConfiguration.getCategories(includingDeleted: true)?.filter({ $0.isArchived || $0.isDeleted }).map({ $0.id }) ?? []
            if !inactiveCategoryIDs.isEmpty {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    // Remove items in reverse order to prevent index shifting
                    var sortedIndexes = [Int]()
                    for (index, categoryID) in primaryConfiguration.categoryIDs.enumerated() {
                        if inactiveCategoryIDs.contains(categoryID) {
                            try Task.checkCancellation()
                            sortedIndexes.append(index)
                        }
                    }
                    sortedIndexes.sort(by: >)
                    for index in sortedIndexes {
                        primaryConfiguration.categoryIDs.remove(at: index)
                    }
                }
            }

            if !otherConfigurations.isEmpty {
                let primaryCategoryIDs = Set(primaryConfiguration.categoryIDs)
                let primaryUserScriptIDs = Set(primaryConfiguration.userScriptIDs)
                
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    // Consolidate categories
                    for otherConfig in otherConfigurations {
                        var newCategories: [FeedCategory] = []
                        for category in otherConfig.getCategories() ?? [] where !category.isArchived && !category.isDeleted {
                            if !primaryCategoryIDs.contains(category.id)
                                && !newCategories.contains(where: { $0.id == category.id }) {
                                newCategories.append(category)
                            }
                        }
                        // Merge newCategories into primaryConfiguration.categories in the correct order
                        for category in newCategories {
                            // Find the index of the last matching category that exists in both primary and otherConfig
                            if let lastMatchingIndex = primaryConfiguration.categoryIDs.lastIndex(where: { otherConfig.categoryIDs.firstIndex(of: $0) != nil }),
                               let insertIndexInPrimary = primaryConfiguration.categoryIDs.index(of: primaryConfiguration.categoryIDs[lastMatchingIndex]) {
                                primaryConfiguration.categoryIDs.insert(category.id, at: insertIndexInPrimary + 1)
                            } else {
                                // If no preceding category exists, append to the end
                                primaryConfiguration.categoryIDs.append(category.id)
                            }
                        }
                    }
                    
                    // Consolidate userScripts
                    for otherConfig in otherConfigurations {
                        var newScripts: [UserScript] = []
                        for script in otherConfig.getUserScripts() ?? [] where !script.isArchived && !script.isDeleted {
                            if !primaryUserScriptIDs.contains(script.id) &&
                                !newScripts.contains(where: { $0.id == script.id }) {
                                newScripts.append(script)
                            }
                        }
                        // Merge newScripts into primaryConfiguration.userScripts in the correct order
                        for script in newScripts {
                            // Find the index of the last matching script that exists in both primary and otherConfig
                            if let lastMatchingIndex = primaryConfiguration.userScriptIDs.lastIndex(where: { otherConfig.userScriptIDs.firstIndex(of: $0) != nil }),
                               let insertIndexInPrimary = primaryConfiguration.userScriptIDs.index(of: primaryConfiguration.userScriptIDs[lastMatchingIndex]) {
                                primaryConfiguration.userScriptIDs.insert(script.id, at: insertIndexInPrimary + 1)
                            } else {
                                // If no preceding script exists, append to the end
                                primaryConfiguration.userScriptIDs.append(script.id)
                            }
                        }
                    }
                    
                    // Delete consolidated configurations
                    for otherConfig in otherConfigurations {
                        otherConfig.isDeleted = true
                        otherConfig.refreshChangeMetadata(explicitlyModified: true)
                    }
                    primaryConfiguration.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            
            // Add orphaned categories
            let updatedCategoryIDs: [UUID] = primaryConfiguration.categoryIDs.map { $0 }
            let orphanCategories = Array(realm.objects(FeedCategory.self).where {
                !$0.isDeleted && !$0.isArchived && !$0.id.in(updatedCategoryIDs)
            })
            if !orphanCategories.isEmpty {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    let existingCategoryIDs = Set(primaryConfiguration.categoryIDs)
                    for category in orphanCategories where !existingCategoryIDs.contains(category.id) {
                        try Task.checkCancellation()
                        primaryConfiguration.categoryIDs.append(category.id)
                    }
                    primaryConfiguration.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            
            return primaryConfiguration
        }
        
        let newConfiguration = LibraryConfiguration()
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.add(newConfiguration, update: .modified)
        }
        return newConfiguration
    }
    
    public override init() {
        super.init()
    }
}

extension OPMLEntry {
    func attributeBoolValue(_ name: String) -> Bool? {
        guard let value = attributes?.first(where: { $0.name == name })?.value else { return nil }
        return value == "true"
    }
    
    func attributeStringValue(_ name: String) -> String? {
        return attributes?.first(where: { $0.name == name })?.value
    }
}

public class LibraryDataManager: NSObject {
    public static let shared = LibraryDataManager()
    
    public static var realmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var currentUsername: String? = nil

    private var importOPMLTask: Task<(), Error>?
    
    @RealmBackgroundActor
    var realmCancellables = Set<AnyCancellable>()
    var cancellables = Set<AnyCancellable>()

    private static let attributeCharacterSet: CharacterSet = .alphanumerics.union(.punctuationCharacters.union(.symbols.union(.whitespaces)))
    
    public override init() {
        super.init()
        
        // TODO: Optimize a lil by only importing changed downloads, not reapplying all downloads on any one changing. Tho it's nice to ensure DLs continuously correctly placed.
        DownloadController.shared.$finishedDownloads
            .debounce(for: .seconds(0.25), scheduler: RunLoop.main)
            .sink(receiveValue: { [weak self] feedDownloads in
                guard let self = self else { return }
                importOPMLTask?.cancel()
                importOPMLTask = Task { @RealmBackgroundActor [weak self] in
                    let opmlDownloads = feedDownloads.filter({ $0.url.lastPathComponent.hasSuffix(".opml") })
                    //                    let libraryConfiguration = try await LibraryConfiguration.get()
                    for download in opmlDownloads {
                        try Task.checkCancellation()
                        //                        if (download.finishedDownloadingDuringCurrentLaunchAt == nil && (download.lastDownloaded ?? Date.distantPast) > libraryConfiguration?.opmlLastImportedAt ?? Date.distantPast) || ((download.finishedDownloadingDuringCurrentLaunchAt ?? .distantPast) > (download.finishedLoadingDuringCurrentLaunchAt ?? .distantPast)) {
                        // ^ Re-enable reloading on every launch:
                        if download.finishedLoadingDuringCurrentLaunchAt == nil || (download.finishedDownloadingDuringCurrentLaunchAt ?? .distantPast) > (download.finishedLoadingDuringCurrentLaunchAt ?? .distantPast) {
                            do {
                                try await self?.importOPML(download: download)
                            } catch {
                                if error as? CancellationError == nil {
                                    print("Failed to import OPML downloaded from \(download.url). Error: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
            })
            .store(in: &cancellables)
        
        //        DownloadController.shared.finishedDownloads.publisher
        //            .print("FOOBAR ")
        //            .collect()
        //            .removeDuplicates()
        //            .combineLatest(DownloadController.shared.failedDownloads.publisher.collect().removeDuplicates())
        //            .compactMap { (finishedDownloads: [Downloadable], failedDownloads: [Downloadable]) -> [Downloadable]? in
        //                if LibraryConfiguration.getOrCreate().downloadables.allSatisfy({
        //                    finishedDownloads.contains($0) || failedDownloads.contains($0)
        //                }) {
        //                    return finishedDownloads.filter {
        //                        LibraryConfiguration.getOrCreate().downloadables.contains($0)
        //                    }
        //                }
        //                return nil
        //            }
        //            .removeDuplicates()
        //            .sink(receiveValue: { [weak self] feedDownloads in
        //                Task.detached { [weak self] in
        //                    for download in feedDownloads {
        //                        print(download.url)
        //                        do {
        //                            try self?.importOPML(download: download)
        //                        } catch {
        //                            print("Failed to import OPML downloaded from \(download.url). Error: \(error.localizedDescription)")
        //                        }
        //                    }
        //                }
        //            })
        //            .store(in: &cancellables)
        
        Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: Self.realmConfiguration)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        guard let self = self else { return }
                        try await refreshScripts()
                    }
                })
                .store(in: &realmCancellables)
            
            realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        guard let self = self else { return }
                        try await refreshScripts()
                    }
                })
                .store(in: &realmCancellables)
        }
    }
    
    @RealmBackgroundActor
    private func refreshScripts() async throws {
        try await Realm.asyncWrite(ThreadSafeReference(to: LibraryConfiguration.getConsolidatedOrCreate()), configuration: LibraryDataManager.realmConfiguration) { realm, configuration in
            let scripts = Array(realm.objects(UserScript.self))
            for script in scripts {
                if script.isDeleted {
                    for (idx, candidateID) in Array(configuration.userScriptIDs).enumerated() {
                        if candidateID == script.id {
                            configuration.userScriptIDs.remove(at: idx)
                            configuration.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                } else if !configuration.userScriptIDs.contains(script.id) {
                    configuration.userScriptIDs.append(script.id)
                    configuration.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
    
    @RealmBackgroundActor
    public func createEmptyCategory(addToLibrary: Bool) async throws -> FeedCategory {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
        let category = FeedCategory()
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.add(category, update: .modified)
        }
        if addToLibrary {
            let configuration = try await LibraryConfiguration.getConsolidatedOrCreate()
            let categoryID = category.id
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                guard !configuration.categoryIDs.contains(where: { $0 == categoryID }) else { return }
                configuration.categoryIDs.append(categoryID)
                configuration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        return category
    }
    
    @RealmBackgroundActor
    public func createEmptyFeed(inCategory category: ThreadSafeReference<FeedCategory>) async throws -> Feed? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration)
        guard let category = realm.resolve(category) else { return nil }
        let feed = Feed()
        feed.categoryID = category.id
        feed.meaningfulContentMinLength = 0
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.add(feed, update: .modified)
        }
        return feed
    }
    
    @RealmBackgroundActor
    public func getOrCreateAppFeed(rssURL: URL, isReaderModeByDefault: Bool, rssContainsFullContent: Bool) async throws -> Feed? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration) 
        var feed = Feed()
        let existingAppFeeds = realm.objects(Feed.self).where({ !$0.isDeleted && $0.categoryID == nil }).filter { $0.rssUrl == rssURL }
        if let existing = existingAppFeeds.first {
            feed = existing
            if feed.meaningfulContentMinLength != 0 || feed.isReaderModeByDefault != isReaderModeByDefault || feed.rssContainsFullContent != rssContainsFullContent || !feed.deleteOrphans {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    feed.deleteOrphans = true
                    feed.isArchived = false
                    feed.meaningfulContentMinLength = 0
                    feed.isReaderModeByDefault = isReaderModeByDefault
                    feed.rssContainsFullContent = rssContainsFullContent
                    feed.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            
            // Delete any duplicate feeds perhaps synced from other devices via iCloud
            let dupeFeeds = existingAppFeeds.filter { $0.id != existing.id }
            if !dupeFeeds.isEmpty {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    for dupeFeed in dupeFeeds {
                        dupeFeed.isDeleted = true
                        dupeFeed.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
        } else {
            feed.deleteOrphans = true
            feed.rssUrl = rssURL
            feed.meaningfulContentMinLength = 0
            feed.isReaderModeByDefault = isReaderModeByDefault
            feed.rssContainsFullContent = rssContainsFullContent
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                realm.add(feed, update: .modified)
            }
        }
        return feed
    }
    
    @RealmBackgroundActor
    public func duplicateFeed(_ feed: ThreadSafeReference<Feed>, inCategory category: ThreadSafeReference<FeedCategory>, overwriteExisting: Bool) async throws -> Feed? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration)
        guard let category = realm.resolve(category), let feed = realm.resolve(feed) else { return nil }
        let existing = category.getFeeds()?.filter { $0.rssUrl == feed.rssUrl && $0.id != feed.id }.first
        let value = try JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(feed))
        value.id = (overwriteExisting ? existing?.id : nil) ?? UUID()
        value.refreshChangeMetadata(explicitlyModified: true)
        value.isDeleted = false
        value.isArchived = false
        value.categoryID = category.id
        var new: Feed?
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            new = realm.create(Feed.self, value: value, update: .modified)
        }
        return new!
    }
    
    @RealmBackgroundActor
    public func createEmptyScript(addToLibrary: Bool) async throws -> UserScript {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
        let script = UserScript()
        script.title = ""
        if addToLibrary {
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                realm.add(script, update: .modified)
            }
            let configuration = try await LibraryConfiguration.getConsolidatedOrCreate()
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                configuration.userScriptIDs.append(script.id)
                configuration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        return script
    }
    
    @RealmBackgroundActor
    public func syncFromServers(isWaiting: Bool) async throws {
        Task.detached { @MainActor in
            let downloadables = try await LibraryConfiguration.getConsolidatedOrCreate().downloadables
            await DownloadController.shared.ensureDownloaded(downloadables)
        }
    }
    
    public func importOPML(fileURLs: [URL]) async {
        for fileURL in fileURLs {
            do {
                try await importOPML(fileURL: fileURL)
            } catch {
                print("Failed to import OPML from local file \(fileURL.absoluteString). Error: \(error.localizedDescription)")
            }
        }
    }
    
    @RealmBackgroundActor
    public func importOPML(fileURL: URL, fromDownload download: Downloadable? = nil) async throws {
        let text = try String(contentsOf: fileURL)
        let opml = try OPML(Data(text.utf8))
        var allImportedCategories = OrderedSet<FeedCategory>()
        var allImportedFeeds = OrderedSet<Feed>()
        var allImportedScripts = OrderedSet<UserScript>()
        let configuration = try await LibraryConfiguration.getConsolidatedOrCreate()
        guard let realm = configuration.realm else { return }
        
        for entry in opml.entries {
            try Task.checkCancellation()
            let (importedCategories, importedFeeds, importedScripts) = try await importOPMLEntry(entry, opml: opml, download: download)
            allImportedCategories.formUnion(importedCategories)
            allImportedFeeds.formUnion(importedFeeds)
            allImportedScripts.formUnion(importedScripts)
        }
        
        let allImportedCategoryIDs = allImportedCategories.map { $0.id }
        let allImportedFeedIDs = allImportedFeeds.map { $0.id }
        let allImportedScriptIDs = allImportedScripts.map { $0.id }
        
        // Delete orphan scripts
        try Task.checkCancellation()
        if let downloadURL = download?.url {
            let filteredScripts = Array(realm.objects(UserScript.self).filter({ !$0.isDeleted && $0.opmlURL == downloadURL }))
            for script in filteredScripts {
                if !allImportedScriptIDs.contains(script.id) {
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        script.isDeleted = true
                    }
                }
                try Task.checkCancellation()
            }
        }
        
        // Add new scripts
        try Task.checkCancellation()
        for script in allImportedScripts {
            if !configuration.userScriptIDs.contains(where: { $0 != script.id }) {
                var lastNeighborIdx = configuration.userScriptIDs.count - 1
                if let downloadURL = download?.url, let userScripts = configuration.getUserScripts() {
                    lastNeighborIdx = userScripts.lastIndex(where: { $0.opmlURL == downloadURL }) ?? lastNeighborIdx
                }
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    configuration.userScriptIDs.insert(script.id, at: lastNeighborIdx + 1)
                    configuration.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            try Task.checkCancellation()
        }
        
        // Move scripts
        try Task.checkCancellation()
        var desiredScripts = allImportedScripts
        for (idx, script) in (configuration.getUserScripts() ?? []).enumerated() {
            if let downloadURL = download?.url, script.opmlURL == downloadURL, !desiredScripts.isEmpty {
                let desiredScript = desiredScripts.removeFirst()
                if let fromIdx = configuration.userScriptIDs.firstIndex(where: { $0 == desiredScript.id }), fromIdx != idx {
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        configuration.userScriptIDs.move(from: fromIdx, to: idx)
                        configuration.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            try Task.checkCancellation()
        }
        
        // De-dupe scripts from library configuration (due to some bug...)
        try Task.checkCancellation()
        var scriptIDsSeen = Set<UUID>()
        var scriptsToRemove = IndexSet()
        for (idx, scriptID) in configuration.userScriptIDs.enumerated() {
            if scriptIDsSeen.contains(scriptID) {
                scriptsToRemove.insert(idx)
            } else {
                scriptIDsSeen.insert(scriptID)
            }
        }
        if !scriptsToRemove.isEmpty {
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                configuration.userScriptIDs.remove(atOffsets: scriptsToRemove)
                configuration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        
        // Delete orphan categories
        try Task.checkCancellation()
        if let downloadURL = download?.url {
            let filteredCategories = Array(realm.objects(FeedCategory.self).filter({ !$0.isDeleted && $0.opmlURL == downloadURL }))
            for category in filteredCategories {
                if !allImportedCategoryIDs.contains(category.id) {
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        category.isDeleted = true
                        category.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            try Task.checkCancellation()
        }
        
        // Delete orphan feeds
        try Task.checkCancellation()
        if let downloadURL = download?.url {
            let filteredFeeds = Array(realm.objects(Feed.self).filter({ !$0.isDeleted && $0.getCategory()?.opmlURL == downloadURL }))
            for feed in filteredFeeds {
                if !allImportedFeedIDs.contains(feed.id) {
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        feed.isDeleted = true
                        feed.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            try Task.checkCancellation()
        }
       
        // Add new categories
        try Task.checkCancellation()
        for category in allImportedCategories {
            if !configuration.categoryIDs.contains(category.id) {
                var lastNeighborIdx = configuration.categoryIDs.count - 1
                if let downloadURL = download?.url {
                    lastNeighborIdx = configuration.getCategories()?.lastIndex(where: { $0.opmlURL == downloadURL }) ?? lastNeighborIdx
                }
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    configuration.categoryIDs.insert(category.id, at: lastNeighborIdx + 1)
                    configuration.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            try Task.checkCancellation()
        }
        
        // Move categories
        try Task.checkCancellation()
        var desiredCategories = allImportedCategories
        for (idx, categoryID) in Array(configuration.categoryIDs).enumerated() {
            if allImportedCategories.map({ $0.id }).contains(categoryID), !desiredCategories.isEmpty {
                let desiredCategory = desiredCategories.removeFirst()
                if let fromIdx = configuration.categoryIDs.firstIndex(of: desiredCategory.id), fromIdx != idx {
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        configuration.categoryIDs.move(from: fromIdx, to: idx)
                        configuration.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            try Task.checkCancellation()
        }
        
        // De-dupe categories from library configuration (due to some bug...)
        try Task.checkCancellation()
        var idsSeen = Set<UUID>()
        var toRemove = IndexSet()
        for (idx, categoryID) in configuration.categoryIDs.enumerated() {
            if idsSeen.contains(categoryID) {
                toRemove.insert(idx)
            } else {
                idsSeen.insert(categoryID)
            }
        }
        if !toRemove.isEmpty {
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                configuration.categoryIDs.remove(atOffsets: toRemove)
                configuration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
    
    @RealmBackgroundActor
    public func importOPML(download: Downloadable) async throws {
        try Task.checkCancellation()
        try await importOPML(fileURL: download.localDestination, fromDownload: download)
        await { @MainActor in
            download.finishedLoadingDuringCurrentLaunchAt = Date()
        }()
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        if let realm = libraryConfiguration.realm {
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                libraryConfiguration.opmlLastImportedAt = Date()
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
    
    @RealmBackgroundActor
    func importOPMLEntry(_ opmlEntry: OPMLEntry, opml: OPML, download: Downloadable?, category: FeedCategory? = nil, importedCategories: OrderedSet<FeedCategory> = OrderedSet(), importedFeeds: OrderedSet<Feed> = OrderedSet(), importedScripts: OrderedSet<UserScript> = OrderedSet()) async throws -> (OrderedSet<FeedCategory>, OrderedSet<Feed>, OrderedSet<UserScript>) {
        var category = category
        let categoryID = category?.id
        var importedCategories = importedCategories
        var importedFeeds = importedFeeds
        var importedScripts = importedScripts
        var uuid: UUID?
        if let rawUUID = opmlEntry.attributeStringValue("uuid") {
            uuid = UUID(uuidString: rawUUID)
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) 

        if opmlEntry.feedURL != nil {
            if let uuid = uuid, let feed = realm.object(ofType: Feed.self, forPrimaryKey: uuid) {
                let feedCategory = feed.getCategory()
                if feedCategory == nil || feedCategory?.opmlURL == download?.url || feed.isDeleted {
                    if Self.hasChanges(opml: opml, opmlEntry: opmlEntry, feed: feed, categoryID: categoryID) {
                        try Task.checkCancellation()
                        let categoryID = categoryID ?? feedCategory?.id
//                        await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, feed: feed, categoryID: categoryID)
                        }
                    }
                    importedFeeds.append(feed)
                }
            } else if opmlEntry.feedURL != nil {
                let feed = Feed()
                if let uuid = uuid, feed.realm == nil {
                    feed.id = uuid
                    try Task.checkCancellation()
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, feed: feed, categoryID: categoryID)
                        realm.add(feed, update: .modified)
                    }
                    importedFeeds.append(feed)
                }
            }
        } else if !(opmlEntry.attributeStringValue("script")?.isEmpty ?? true) {
            if let uuid = uuid, let script = realm.objects(UserScript.self).filter({ $0.id == uuid }).first {
                if script.opmlURL == download?.url || script.isDeleted {
                    if Self.hasChanges(opml: opml, opmlEntry: opmlEntry, script: script) {
                        try Task.checkCancellation()
//                        await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, script: script)
                            try Self.applyScriptDomains(opml: opml, opmlEntry: opmlEntry, script: script)
                        }
                    }
                    importedScripts.append(script)
                }
            } else {
                let script = UserScript()
                if let uuid = uuid, script.realm == nil {
                    script.id = uuid
                    if let downloadURL = download?.url {
                        script.opmlURL = downloadURL
                    }
                    try Task.checkCancellation()
//                    await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, script: script)
                        realm.add(script, update: .modified)
                        try Self.applyScriptDomains(opml: opml, opmlEntry: opmlEntry, script: script)
                    }
                    importedScripts.append(script)
                }
            }
        } else if !(opmlEntry.children?.isEmpty ?? true) {
//            let opmlTitle = opmlEntry.title ?? opmlEntry.text
            if category == nil, !(opmlEntry.attributes?.contains(where: { $0.name == "isUserScriptList" }) ?? false) {
                if let uuid, let existingCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: uuid) {
                    category = existingCategory
                    if Self.hasChanges(opml: opml, opmlEntry: opmlEntry, category: existingCategory) {
                        //                        if existingCategory.opmlURL == download?.url || existingCategory.isDeleted {
//                        await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, category: existingCategory)
                        }
                    }
                    importedCategories.append(existingCategory)
                    //                        }
                } else if let uuid = uuid {
                    category = FeedCategory()
                    if let category = category {
                        category.id = uuid
                        if let downloadURL = download?.url {
                            category.opmlURL = downloadURL
                        }
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, category: category)
//                        await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            realm.add(category, update: .modified)
                        }
                        importedCategories.append(category)
                    }
                }
            }// else if let category = category {
                // Ignore/flatten nested categories from OPML.
            //}
        }
        
        for childEntry in (opmlEntry.children ?? []) {
            try Task.checkCancellation()
            let (newCategories, newFeeds, newScripts) = try await importOPMLEntry(
                childEntry,
                opml: opml,
                download: download,
                category: category,
                importedCategories: importedCategories,
                importedFeeds: importedFeeds,
                importedScripts: importedScripts
            )
            importedCategories.append(contentsOf: newCategories)
            importedFeeds.append(contentsOf: newFeeds)
            importedScripts.append(contentsOf: newScripts)
        }
        return (importedCategories, importedFeeds, importedScripts)
    }
    
    static func applyScriptDomains(opml: OPML, opmlEntry: OPMLEntry, script: UserScript) throws {
        guard let realm = script.realm else { return }
        let domains: [String] = opmlEntry.attributeStringValue("allowedDomains")?.split(separator: ",").compactMap { $0.removingPercentEncoding } ?? []
//        script.allowedDomains.removeAll()
        let allowedDomainIDs = Array(script.allowedDomainIDs)
        for (idx, existingDomainID) in allowedDomainIDs.enumerated() {
            guard let existingDomain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: existingDomainID), !existingDomain.isDeleted else {
                script.allowedDomainIDs.remove(at: idx)
                continue
            }
            if !domains.contains(existingDomain.domain) {
                existingDomain.isDeleted = true
                script.allowedDomainIDs.remove(at: idx)
            } else if existingDomain.isDeleted {
                existingDomain.isDeleted = false
            }
        }
        let existingDomains = script.getAllowedDomains()?.map { $0.domain } ?? []
        for domain in domains {
            if !existingDomains.contains(domain) {
                let newDomain = UserScriptAllowedDomain()
                newDomain.domain = domain
                realm.add(newDomain, update: .modified)
                script.allowedDomainIDs.append(newDomain.id)
            }
        }
        // TODO: Clean up orphan domain objects that appear due to some bug...
    }
    
    static func hasChanges(opml: OPML, opmlEntry: OPMLEntry, script: UserScript) -> Bool {
        if script.title != opmlEntry.text {
            return true
        }
        let newScript = opmlEntry.attributeStringValue("script")?.removingPercentEncoding ?? ""
        if script.script != newScript {
            return true
        }
        let newAllowedDomains = opmlEntry.attributeStringValue("allowedDomains")?.split(separator: ",").compactMap { $0.removingPercentEncoding }
        if Set(script.getAllowedDomains()?.map({ $0.domain }) ?? []) != Set(newAllowedDomains ?? []) {
            return true
        }
        let newInjectAtStart = opmlEntry.attributeBoolValue("injectAtStart") ?? false
        if script.injectAtStart != newInjectAtStart {
            return true
        }
        let newMainFrameOnly = opmlEntry.attributeBoolValue("mainFrameOnly") ?? false
        if script.mainFrameOnly != newMainFrameOnly {
            return true
        }
        let newSandboxed = opmlEntry.attributeBoolValue("sandboxed") ?? false
        if script.sandboxed != newSandboxed {
            return true
        }
        let newIsArchived = opmlEntry.attributeBoolValue("isArchived") ?? true
        if script.isArchived != newIsArchived {
            return true
        }
        let newPreviewURL = URL(string: opmlEntry.attributeStringValue("previewURL") ?? "about:blank")
        if script.previewURL != newPreviewURL {
            return true
        }
        let newOpmlOwnerName = opml.ownerName ?? script.opmlOwnerName
        if script.opmlOwnerName != newOpmlOwnerName {
            return true
        }
        if script.isDeleted {
            return true
        }
        if script.isArchived {
            return true
        }
        return false
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, script: UserScript) throws {
        // Must be kept in sync with respective hasChanges
        var didChange = false
        
        if script.title != opmlEntry.text {
            script.title = opmlEntry.text
            didChange = true
        }
        let newScript = opmlEntry.attributeStringValue("script")?.removingPercentEncoding ?? ""
        if script.script != newScript {
            script.script = newScript
            didChange = true
        }
        let newInjectAtStart = opmlEntry.attributeBoolValue("injectAtStart") ?? false
        if script.injectAtStart != newInjectAtStart {
            script.injectAtStart = newInjectAtStart
            didChange = true
        }
        let newMainFrameOnly = opmlEntry.attributeBoolValue("mainFrameOnly") ?? false
        if script.mainFrameOnly != newMainFrameOnly {
            script.mainFrameOnly = newMainFrameOnly
            didChange = true
        }
        let newSandboxed = opmlEntry.attributeBoolValue("sandboxed") ?? false
        if script.sandboxed != newSandboxed {
            script.sandboxed = newSandboxed
            didChange = true
        }
        let newIsArchived = opmlEntry.attributeBoolValue("isArchived") ?? true
        if script.isArchived != newIsArchived {
            script.isArchived = newIsArchived
            didChange = true
        }
        let newPreviewURL = URL(string: opmlEntry.attributeStringValue("previewURL") ?? "about:blank")
        if script.previewURL != newPreviewURL {
            script.previewURL = newPreviewURL
            didChange = true
        }
        let newOpmlOwnerName = opml.ownerName ?? script.opmlOwnerName
        if script.opmlOwnerName != newOpmlOwnerName {
            script.opmlOwnerName = newOpmlOwnerName
            didChange = true
        }
        
        if script.isDeleted {
            script.isDeleted = false
            didChange = true
        }
        if script.isArchived {
            script.isArchived = false
            didChange = true
        }
        
        if didChange {
            script.refreshChangeMetadata(explicitlyModified: true)
        }
    }
    
    static func hasChanges(opml: OPML, opmlEntry: OPMLEntry, category: FeedCategory) -> Bool {
        if opmlEntry.attributeUUIDValue("uuid") != category.id {
            return true
        }
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        if category.title != newOpmlTitle {
            return true
        }
        let newOpmlOwnerName = opml.ownerName ?? category.opmlOwnerName
        if category.opmlOwnerName != newOpmlOwnerName {
            return true
        }
        let newBackgroundImageURL = opmlEntry.attributeStringValue("backgroundImageUrl")
        if let newBackgroundImageURL = newBackgroundImageURL, let newURL = URL(string: newBackgroundImageURL), category.backgroundImageUrl != newURL {
            return true
        }
        if category.isDeleted {
            return true
        }
        if opmlEntry.attributeBoolValue("isCommented") ?? false {
            if !category.isArchived {
                return true
            }
        } else if category.isArchived {
            return true
        }
        return false
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, category: FeedCategory) throws {
        // Must be kept in sync with the respective hasChanges
        var didChange = false
        
        let newBackgroundImageURL = opmlEntry.attributeStringValue("backgroundImageUrl")
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        
        if category.title != newOpmlTitle {
            category.title = newOpmlTitle
            didChange = true
        }
        let newOpmlOwnerName = opml.ownerName ?? category.opmlOwnerName
        if category.opmlOwnerName != newOpmlOwnerName {
            category.opmlOwnerName = newOpmlOwnerName
            didChange = true
        }
        if let newBackgroundImageURL = newBackgroundImageURL, let newURL = URL(string: newBackgroundImageURL), category.backgroundImageUrl != newURL {
            category.backgroundImageUrl = newURL
            didChange = true
        }
        
        if category.isDeleted {
            category.isDeleted = false
            didChange = true
        }
        if opmlEntry.attributeBoolValue("isCommented") ?? false {
            if !category.isArchived {
                category.isArchived = true
                didChange = true
            }
        } else if category.isArchived {
            category.isArchived = false
            didChange = true
        }
        
        if didChange {
            category.refreshChangeMetadata(explicitlyModified: true)
        }
    }
    
    static func hasChanges(opml: OPML, opmlEntry: OPMLEntry, feed: Feed, categoryID: UUID?) -> Bool {
        guard let feedURL = opmlEntry.feedURL else { return false }
        if feed.categoryID != categoryID {
            return true
        }
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        if feed.title != newOpmlTitle {
            return true
        }
        let newMarkdownDescription = opmlEntry.attributeStringValue("markdownDescription") ?? feed.markdownDescription
        if feed.markdownDescription != newMarkdownDescription {
            return true
        }
        if feed.rssUrl != feedURL {
            return true
        }
        var newIconURL: URL?
        if let iconURLRaw = opmlEntry.attributeStringValue("iconUrl") {
            newIconURL = URL(string: iconURLRaw)
        }
        if let newIconURL = newIconURL, feed.iconUrl != newIconURL {
            return true
        }
        let newIsReaderModeByDefault = opmlEntry.attributeBoolValue("isReaderModeByDefault") ?? true
        if feed.isReaderModeByDefault != newIsReaderModeByDefault {
            return true
        }
        let newRssContainsFullContent = opmlEntry.attributeBoolValue("rssContainsFullContent") ?? false
        if feed.rssContainsFullContent != newRssContainsFullContent {
            return true
        }
        let newInjectEntryImageIntoHeader = opmlEntry.attributeBoolValue("injectEntryImageIntoHeader") ?? false
        if feed.injectEntryImageIntoHeader != newInjectEntryImageIntoHeader {
            return true
        }
        let newDisplayPublicationDate = opmlEntry.attributeBoolValue("displayPublicationDate") ?? true
        if feed.displayPublicationDate != newDisplayPublicationDate {
            return true
        }
        if let newMeaningfulContentMinLength = opmlEntry.attributeStringValue("meaningfulContentMinLength"), let meaningfulContentMinLengthInt = Int(newMeaningfulContentMinLength), feed.meaningfulContentMinLength != meaningfulContentMinLengthInt {
            return true
        }
        let newExtractImageFromContent = opmlEntry.attributeBoolValue("extractImageFromContent") ?? true
        if feed.extractImageFromContent != newExtractImageFromContent {
            return true
        }
        if feed.isDeleted {
            return true
        }
        if opmlEntry.attributeBoolValue("isCommented") ?? false {
            if !feed.isArchived {
                return true
            }
        } else if feed.isArchived {
            return true
        }
        return false
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, feed: Feed, categoryID: UUID?) throws {
        // Must be kept in sync with the respective hasChanges
        guard let feedURL = opmlEntry.feedURL else { return }
        
        var didChange = false
        
        var newIconURL: URL?
        if let iconURLRaw = opmlEntry.attributeStringValue("iconUrl") {
            newIconURL = URL(string: iconURLRaw)
        }
        
        if feed.categoryID != categoryID {
            feed.categoryID = categoryID
            didChange = true
        }
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        if feed.title != newOpmlTitle {
            feed.title = newOpmlTitle
            didChange = true
        }
        let newMarkdownDescription = opmlEntry.attributeStringValue("markdownDescription") ?? feed.markdownDescription
        if feed.markdownDescription != newMarkdownDescription {
            feed.markdownDescription = newMarkdownDescription
            didChange = true
        }
        if feed.rssUrl != feedURL {
            feed.rssUrl = feedURL
            didChange = true
        }
        if let newIconURL = newIconURL, feed.iconUrl != newIconURL {
            feed.iconUrl = newIconURL
            didChange = true
        }
        let newIsReaderModeByDefault = opmlEntry.attributeBoolValue("isReaderModeByDefault") ?? true
        if feed.isReaderModeByDefault != newIsReaderModeByDefault {
            feed.isReaderModeByDefault = newIsReaderModeByDefault
            didChange = true
        }
        let newRssContainsFullContent = opmlEntry.attributeBoolValue("rssContainsFullContent") ?? false
        if feed.rssContainsFullContent != newRssContainsFullContent {
            feed.rssContainsFullContent = newRssContainsFullContent
            didChange = true
        }
        let newInjectEntryImageIntoHeader = opmlEntry.attributeBoolValue("injectEntryImageIntoHeader") ?? false
        if feed.injectEntryImageIntoHeader != newInjectEntryImageIntoHeader {
            feed.injectEntryImageIntoHeader = newInjectEntryImageIntoHeader
            didChange = true
        }
        let newDisplayPublicationDate = opmlEntry.attributeBoolValue("displayPublicationDate") ?? true
        if feed.displayPublicationDate != newDisplayPublicationDate {
            feed.displayPublicationDate = newDisplayPublicationDate
            didChange = true
        }
        if let newMeaningfulContentMinLength = opmlEntry.attributeStringValue("meaningfulContentMinLength"), let meaningfulContentMinLengthInt = Int(newMeaningfulContentMinLength), feed.meaningfulContentMinLength != meaningfulContentMinLengthInt {
            feed.meaningfulContentMinLength = meaningfulContentMinLengthInt
            didChange = true
        }
        let newExtractImageFromContent = opmlEntry.attributeBoolValue("extractImageFromContent") ?? true
        if feed.extractImageFromContent != newExtractImageFromContent {
            feed.extractImageFromContent = newExtractImageFromContent
            didChange = true
        }
        
        if feed.isDeleted {
            feed.isDeleted = false
            didChange = true
        }
        
        if opmlEntry.attributeBoolValue("isCommented") ?? false {
            if !feed.isArchived {
                feed.isArchived = true
                didChange = true
            }
        } else if feed.isArchived {
            feed.isArchived = false
            didChange = true
        }
        
        if didChange {
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
    }
    
    @RealmBackgroundActor
    public func exportUserOPML() async throws -> OPML {
        let configuration = try await LibraryConfiguration.getConsolidatedOrCreate()
        let userCategories = (configuration.getCategories() ?? []).filter { $0.opmlOwnerName == nil && $0.opmlURL == nil }
        
        let scriptEntries = OPMLEntry(text: "User Scripts", attributes: [
            Attribute(name: "isUserScriptList", value: "true"),
        ], children: (configuration.getUserScripts() ?? []).filter({ $0.opmlURL == nil }).map({ script in
            return OPMLEntry(text: script.title, attributes: [
                Attribute(name: "uuid", value: script.id.uuidString),
                Attribute(name: "allowedDomains", value: (script.getAllowedDomains()?.compactMap { $0.domain.addingPercentEncoding(withAllowedCharacters: Self.attributeCharacterSet) }  ?? []).joined(separator: ",")),
                Attribute(name: "script", value: script.script.addingPercentEncoding(withAllowedCharacters: Self.attributeCharacterSet) ?? script.script),
                Attribute(name: "injectAtStart", value: script.injectAtStart ? "true" : "false"),
                Attribute(name: "mainFrameOnly", value: script.mainFrameOnly ? "true" : "false"),
                Attribute(name: "sandboxed", value: script.sandboxed ? "true" : "false"),
                Attribute(name: "isArchived", value: script.isArchived ? "true" : "false"),
                Attribute(name: "previewURL", value: script.previewURL?.absoluteString ?? "about:blank"),
            ])
        }))
        
        let opml = OPML(
            dateModified: Date(),
            ownerName: (Self.currentUsername?.isEmpty ?? true) ? nil : Self.currentUsername,
            entries: try [scriptEntries] + (userCategories ?? []).map { category in
                try Task.checkCancellation()
                
                return OPMLEntry(
                    text: category.title,
                    attributes: [
                        Attribute(name: "uuid", value: category.id.uuidString),
                        Attribute(name: "backgroundImageUrl", value: category.backgroundImageUrl.absoluteString),
                        Attribute(name: "isFeedCategory", value: "true"),
                    ],
                    children: try (category.getFeeds() ?? []).filter({ !$0.isArchived }).map { feed in
                        try Task.checkCancellation()
                        
                        var attributes = [
                            Attribute(name: "uuid", value: feed.id.uuidString),
                            Attribute(name: "extractImageFromContent", value: feed.extractImageFromContent ? "true" : "false"),
                            Attribute(name: "isReaderModeByDefault", value: feed.isReaderModeByDefault ? "true" : "false"),
                            Attribute(name: "iconUrl", value: feed.iconUrl.absoluteString),
                        ]
                        if !feed.markdownDescription.isEmpty {
                            attributes.append(Attribute(name: "markdownDescription", value: feed.markdownDescription))
                        }
                        attributes.append(Attribute(name: "rssContainsFullContent", value: feed.rssContainsFullContent ? "true" : "false"))
                        attributes.append(Attribute(name: "injectEntryImageIntoHeader", value: feed.injectEntryImageIntoHeader ? "true" : "false"))
                        attributes.append(Attribute(name: "displayPublicationDate", value: feed.displayPublicationDate ? "true" : "false"))
                        attributes.append(Attribute(name: "meaningfulContentMinLength", value: String(feed.meaningfulContentMinLength)))
                        return OPMLEntry(
                            rss: feed.rssUrl,
                            siteURL: nil,
                            title: feed.title,
                            attributes: attributes)
                    })
            })
        return opml
    }
}
