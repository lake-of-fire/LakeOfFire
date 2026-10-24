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
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock

public let libraryDataQueue = DispatchQueue(label: "LibraryDataQueue")

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
    nonisolated(unsafe) public static var securityApplicationGroupIdentifier = ""
    nonisolated(unsafe) public static var downloadstDirectoryName = "library-configuration"
    nonisolated(unsafe) public static var opmlURLs = [URL]()

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var opmlLastImportedAt: Date?
    
    @Persisted public var categoryIDs: RealmSwift.List<UUID>
    @Persisted public var userScriptIDs: RealmSwift.List<UUID>
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    @MainActor
    public var systemScripts: [WebViewUserScript] {
        Self.sharedSystemScripts
    }

    @MainActor
    public static var sharedSystemScripts: [WebViewUserScript] {
        [
            Readability.shared.userScript,
            ReadabilityImagesUserScript.shared.userScript,
//            ReaderConsoleLogsUserScript.shared.userScript,
//            ManabiReaderUserScript().userScript,
//            YoutubeAdBlockUserScript.userScript,
//            YoutubeAdSkipUserScript.userScript,
//            YoutubeCaptionsUserScript.userScript,
        ]
    }
    
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
        Self.configuredDownloadables
    }

    /// Download descriptors depend only on process configuration, not managed
    /// Realm fields. Keeping their construction static avoids sending a managed
    /// `LibraryConfiguration` across actors merely to read this value.
    @MainActor
    public static var configuredDownloadables: Set<Downloadable> {
        guard !Self.securityApplicationGroupIdentifier.isEmpty else { fatalError("securityApplicationGroupIdentifier unset") }
        let controller = DownloadController.shared
        return Set(Self.opmlURLs.compactMap { url in
            if let downloadable = controller.assuredDownloads.first(where: { $0.url == url }) {
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
    
    @MainActor
    public func getActiveWebViewUserScripts() -> [WebViewUserScript]? {
        getActiveWebViewUserScriptDescriptors()?.map { $0.makeUserScript() }
    }

    public func getActiveWebViewUserScriptDescriptors() -> [WebViewUserScriptDescriptor]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return Array(getUserScripts()?.filter { !$0.isArchived }.compactMap { $0.getWebViewUserScriptDescriptor() } ?? [])
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

    public func attributeUUIDValue(_ name: String) -> UUID? {
        return attributeStringValue(name).flatMap(UUID.init(uuidString:))
    }
}

// Task-scoped rollback observation of the actual import transaction. No hook is
// installed during normal imports, and no alternate mutation path is provided.
enum LibraryOPMLImportObservation {
    @TaskLocal static var beforeCommit: (@RealmBackgroundActor @Sendable () throws -> Void)? = nil
}

public class LibraryDataManager: NSObject, @unchecked Sendable {
    nonisolated(unsafe) public static let shared = LibraryDataManager()
    
    nonisolated(unsafe) public static var realmConfiguration: Realm.Configuration = DefaultRealmConfiguration.configuration
    nonisolated(unsafe) public static var currentUsername: String? = nil

    private var importOPMLTask: Task<(), Error>?
    
    @RealmBackgroundActor
    var realmCancellables = Set<AnyCancellable>()
    @MainActor
    var cancellables = Set<AnyCancellable>()

    nonisolated(unsafe) public static var observesDownloadController = true

    private static let attributeCharacterSet: CharacterSet = .alphanumerics.union(.punctuationCharacters.union(.symbols.union(.whitespaces)))

    @MainActor
    private static var downloadController: DownloadController {
        DownloadController.shared
    }
    
    public override convenience init() {
        self.init(observesChanges: true)
    }

    public init(observesChanges: Bool) {
        super.init()
        guard observesChanges else { return }

        guard Self.observesDownloadController else { return }
        
        // TODO: Optimize a lil by only importing changed downloads, not reapplying all downloads on any one changing. Tho it's nice to ensure DLs continuously correctly placed.
        Task { @MainActor in
            Self.downloadController.$finishedDownloads
                .debounceLeadingTrailing(for: .seconds(0.25), scheduler: RunLoop.main)
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
                                    }
                                }
                            } else {
                            }
                        }
                    }
                })
                .store(in: &cancellables)
        }
        
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
        
        let realmConfiguration = Self.realmConfiguration
        Task { @RealmBackgroundActor in
            guard realmConfiguration.fileURL != nil || realmConfiguration.inMemoryIdentifier != nil else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        guard let self = self else { return }
                        try await refreshScripts()
                    }
                })
                .store(in: &realmCancellables)
            
            realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
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
    public func createEmptyCategory(addToLibrary: Bool) async throws -> UUID {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
        let category = FeedCategory()
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.add(category, update: .modified)
            category.refreshChangeMetadata(explicitlyModified: true)
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
        return category.id
    }
    
    @RealmBackgroundActor
    public func createEmptyFeed(inCategory category: ThreadSafeReference<FeedCategory>) async throws -> UUID? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration)
        guard let category = realm.resolve(category) else { return nil }
        let feed = Feed()
        feed.categoryID = category.id
        feed.meaningfulContentMinLength = 0
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.add(feed, update: .modified)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        return feed.id
    }
    
    @RealmBackgroundActor
    public func getOrCreateAppFeed(
        rssURL: URL,
        isReaderModeByDefault: Bool,
        rssContainsFullContent: Bool,
        title: String? = nil,
        iconURL: URL? = nil
    ) async throws -> Feed? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration) 
        var feed = Feed()
        let existingAppFeeds = realm.objects(Feed.self).where({ !$0.isDeleted && $0.categoryID == nil }).filter { $0.rssUrl == rssURL }
        if let existing = existingAppFeeds.first {
            feed = existing
            let shouldUpdateTitle = title.map { feed.title != $0 } ?? false
            let shouldUpdateIcon = iconURL.map { feed.iconUrl != $0 } ?? false
            if feed.meaningfulContentMinLength != 0 ||
                feed.isReaderModeByDefault != isReaderModeByDefault ||
                feed.rssContainsFullContent != rssContainsFullContent ||
                !feed.deleteOrphans ||
                shouldUpdateTitle ||
                shouldUpdateIcon {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    feed.deleteOrphans = true
                    feed.isArchived = false
                    feed.meaningfulContentMinLength = 0
                    feed.isReaderModeByDefault = isReaderModeByDefault
                    feed.rssContainsFullContent = rssContainsFullContent
                    if let title {
                        feed.title = title
                    }
                    if let iconURL {
                        feed.iconUrl = iconURL
                    }
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
            if let title {
                feed.title = title
            }
            if let iconURL {
                feed.iconUrl = iconURL
            }
            feed.meaningfulContentMinLength = 0
            feed.isReaderModeByDefault = isReaderModeByDefault
            feed.rssContainsFullContent = rssContainsFullContent
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                realm.add(feed, update: .modified)
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        return feed
    }
    
    @RealmBackgroundActor
    public func duplicateFeed(_ feed: ThreadSafeReference<Feed>, inCategory category: ThreadSafeReference<FeedCategory>, overwriteExisting: Bool) async throws -> UUID? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration)
        guard let category = realm.resolve(category), let feed = realm.resolve(feed) else { return nil }
        let existing = category.getFeeds()?.filter { $0.rssUrl == feed.rssUrl && $0.id != feed.id }.first
        let value = try JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(feed))
        value.id = (overwriteExisting ? existing?.id : nil) ?? UUID()
        value.isDeleted = false
        value.isArchived = false
        value.categoryID = category.id
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            let duplicatedFeed = realm.create(Feed.self, value: value, update: .modified)
            duplicatedFeed.refreshChangeMetadata(explicitlyModified: true)
        }
        return value.id
    }
    
    @RealmBackgroundActor
    public func createEmptyScript(addToLibrary: Bool) async throws -> UUID {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
        let script = UserScript()
        script.title = ""
        if addToLibrary {
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                realm.add(script, update: .modified)
                script.refreshChangeMetadata(explicitlyModified: true)
            }
            let configuration = try await LibraryConfiguration.getConsolidatedOrCreate()
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                configuration.userScriptIDs.append(script.id)
                configuration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        return script.id
    }
    
    @RealmBackgroundActor
    public func syncFromServers() async throws {
        // Creating/consolidating the Realm row remains part of this operation, but
        // the descriptors themselves contain no Realm-backed state.
        _ = try await LibraryConfiguration.getConsolidatedOrCreate()
        await Task { @MainActor in
            await DownloadController.shared.ensureDownloaded(
                LibraryConfiguration.configuredDownloadables
            )
        }.value
    }
    
    public func importOPML(
        fileURLs: [URL],
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) async {
        let storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        for fileURL in fileURLs {
            do {
                _ = try await performOPMLImport(
                    fileURL: fileURL, downloadURL: nil,
                    realmConfiguration: realmConfiguration, storageAdmission: storageAdmission,
                    recordsDownloadCompletion: false
                )
            } catch {
                if error is CancellationError { return }
                print("Failed to import OPML from local file \(fileURL.absoluteString). Error: \(error.localizedDescription)")
                guard storageAdmission.matchesCurrentStorageIdentity({
                    RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
                }) else { return }
            }
        }
    }
    
    @RealmBackgroundActor
    public func importOPML(fileURL: URL, fromDownload download: Downloadable? = nil, realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration) async throws {
        let storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        _ = try await performOPMLImport(
            fileURL: fileURL, downloadURL: download?.url,
            realmConfiguration: realmConfiguration, storageAdmission: storageAdmission,
            recordsDownloadCompletion: false
        )
    }

    @RealmBackgroundActor
    private func performOPMLImport(
        fileURL: URL,
        downloadURL: URL?,
        realmConfiguration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission,
        recordsDownloadCompletion: Bool
    ) async throws -> Date {
        try Task.checkCancellation()
        // This timestamp describes the file read, not a delayed publication.
        // A later completed download must still compare newer than this import.
        let readAt = Date()
        let text = try String(contentsOf: fileURL)
        let opml = try OPML(Data(text.utf8))
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            let timestamp = Date()
            let configuration = try LibraryConfiguration.consolidateOrCreate(in: realm, at: timestamp)
            try applyOPML(opml, downloadURL: downloadURL, in: realm,
                          configuration: configuration, at: timestamp)
            if recordsDownloadCompletion, configuration.opmlLastImportedAt != readAt {
                configuration.opmlLastImportedAt = readAt
                configuration.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            }
            try LibraryOPMLImportObservation.beforeCommit?()
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        }
        return readAt
    }

    @RealmBackgroundActor
    private func applyOPML(
        _ opml: OPML,
        downloadURL: URL?,
        in realm: Realm,
        configuration: LibraryConfiguration,
        at timestamp: Date
    ) throws {
        precondition(realm.isInWriteTransaction)
        var allImportedCategories = OrderedSet<FeedCategory>()
        var allImportedDirectories = OrderedSet<FeedDirectory>()
        var allImportedFeeds = OrderedSet<Feed>()
        var allImportedScripts = OrderedSet<UserScript>()
        
        for entry in opml.entries {
            try Task.checkCancellation()
            let (importedCategories, importedDirectories, importedFeeds, importedScripts) = try applyOPMLEntry(entry, opml: opml, downloadURL: downloadURL, in: realm, at: timestamp)
            allImportedCategories.formUnion(importedCategories)
            allImportedDirectories.formUnion(importedDirectories)
            allImportedFeeds.formUnion(importedFeeds)
            allImportedScripts.formUnion(importedScripts)
        }
        
        let allImportedCategoryIDs = allImportedCategories.map { $0.id }
        let allImportedDirectoryIDs = allImportedDirectories.map { $0.id }
        let allImportedFeedIDs = allImportedFeeds.map { $0.id }
        let allImportedScriptIDs = allImportedScripts.map { $0.id }
        
        // Delete orphan scripts
        try Task.checkCancellation()
        if let downloadURL = downloadURL {
            let filteredScripts = Array(realm.objects(UserScript.self).filter({ !$0.isDeleted && $0.opmlURL == downloadURL }))
            for script in filteredScripts {
                if !allImportedScriptIDs.contains(script.id) {
                    script.isDeleted = true
                    script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                try Task.checkCancellation()
            }
        }
        
        // Delete orphan categories
        try Task.checkCancellation()
        if let downloadURL = downloadURL {
            let filteredCategories = Array(realm.objects(FeedCategory.self).filter({ !$0.isDeleted && $0.opmlURL == downloadURL }))
            for category in filteredCategories {
                if !allImportedCategoryIDs.contains(category.id) {
                    category.isDeleted = true
                    category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try Task.checkCancellation()
        }
        
        // Delete orphan feeds
        try Task.checkCancellation()
        if let downloadURL = downloadURL {
            let filteredFeeds = Array(realm.objects(Feed.self).filter({ !$0.isDeleted && $0.getCategory()?.opmlURL == downloadURL }))
            for feed in filteredFeeds {
                if !allImportedFeedIDs.contains(feed.id) {
                    feed.isDeleted = true
                    feed.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try Task.checkCancellation()
        }

        // Delete orphan directories
        try Task.checkCancellation()
        if let downloadURL = downloadURL {
            let filteredDirectories = Array(realm.objects(FeedDirectory.self).filter({ !$0.isDeleted && $0.opmlURL == downloadURL }))
            for directory in filteredDirectories {
                if !allImportedDirectoryIDs.contains(directory.id) {
                    directory.isDeleted = true
                    directory.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try Task.checkCancellation()
        }
       
        // Resolve list placement from the same transaction that imported and
        // tombstoned the rows. Filtered model arrays do not share Realm-list indexes.
        func reconciledIdentifiers(
            current: [UUID],
            imported: [UUID],
            sourceNeighborIDs: Set<UUID>,
            reorderImported: Bool
        ) -> [UUID] {
            var result = orderedUniqueLibraryIdentifiers(current)
            let desired = orderedUniqueLibraryIdentifiers(imported)
            let present = Set(result)
            let additions = desired.filter { !present.contains($0) }
            let insertion = result.lastIndex(where: {
                sourceNeighborIDs.contains($0)
            }).map { $0 + 1 } ?? result.count
            result.insert(contentsOf: additions, at: insertion)
            if reorderImported {
                let desiredSet = Set(desired)
                let positions = result.indices.filter { desiredSet.contains(result[$0]) }
                for (position, identifier) in zip(positions, desired) {
                    result[position] = identifier
                }
            }
            return result
        }

        let currentCategoryIDs = Array(configuration.categoryIDs)
        let currentScriptIDs = Array(configuration.userScriptIDs)
        // Missing rows may still be in transit. Remove only known tombstones,
        // and preserve #286's disabled-script membership policy.
        let retainedCategoryIDs = currentCategoryIDs.filter {
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: $0) else {
                return true
            }
            return !category.isDeleted && !category.isArchived
        }
        let retainedScriptIDs = currentScriptIDs.filter {
            realm.object(ofType: UserScript.self, forPrimaryKey: $0)
                .map { !$0.isDeleted } ?? true
        }
        let categoryNeighbors = Set(retainedCategoryIDs.filter {
            guard let downloadURL,
                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: $0) else {
                return false
            }
            return category.opmlURL == downloadURL
        })
        let scriptNeighbors = Set(retainedScriptIDs.filter {
            guard let downloadURL,
                  let script = realm.object(ofType: UserScript.self, forPrimaryKey: $0) else {
                return false
            }
            return script.opmlURL == downloadURL
        })
        let finalCategoryIDs = reconciledIdentifiers(
            current: retainedCategoryIDs,
            imported: allImportedCategories.filter { !$0.isDeleted && !$0.isArchived }.map(\.id),
            sourceNeighborIDs: categoryNeighbors,
            reorderImported: true
        )
        let finalScriptIDs = reconciledIdentifiers(
            current: retainedScriptIDs,
            imported: allImportedScriptIDs,
            sourceNeighborIDs: scriptNeighbors,
            reorderImported: downloadURL != nil
        )
        try Task.checkCancellation()
        guard finalCategoryIDs != currentCategoryIDs || finalScriptIDs != currentScriptIDs else {
            return
        }
        if finalCategoryIDs != currentCategoryIDs {
            configuration.categoryIDs.removeAll()
            configuration.categoryIDs.append(objectsIn: finalCategoryIDs)
        }
        if finalScriptIDs != currentScriptIDs {
            configuration.userScriptIDs.removeAll()
            configuration.userScriptIDs.append(objectsIn: finalScriptIDs)
        }
        configuration.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
    }

    @RealmBackgroundActor
    public func importOPML(download: Downloadable) async throws {
        let realmConfiguration = LibraryDataManager.realmConfiguration
        let storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let readAt = try await performOPMLImport(
            fileURL: download.localDestination, downloadURL: download.url,
            realmConfiguration: realmConfiguration, storageAdmission: storageAdmission,
            recordsDownloadCompletion: true
        )
        await { @MainActor in
            guard !Task.isCancelled,
                  storageAdmission.matchesCurrentStorageIdentity({
                      RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
                  }) else { return }
            download.finishedLoadingDuringCurrentLaunchAt = readAt
        }()
    }

    @RealmBackgroundActor
    private func applyOPMLEntry(
        _ opmlEntry: OPMLEntry,
        opml: OPML,
        downloadURL: URL?,
        category: FeedCategory? = nil,
        directory: FeedDirectory? = nil,
        ordinal: Int? = nil,
        in realm: Realm,
        at timestamp: Date,
        importedCategories: OrderedSet<FeedCategory> = OrderedSet(),
        importedDirectories: OrderedSet<FeedDirectory> = OrderedSet(),
        importedFeeds: OrderedSet<Feed> = OrderedSet(),
        importedScripts: OrderedSet<UserScript> = OrderedSet()
    ) throws -> (OrderedSet<FeedCategory>, OrderedSet<FeedDirectory>, OrderedSet<Feed>, OrderedSet<UserScript>) {
        var category = category
        var directory = directory
        let categoryID = category?.id
        let directoryID = directory?.id
        var importedCategories = importedCategories
        var importedDirectories = importedDirectories
        var importedFeeds = importedFeeds
        var importedScripts = importedScripts
        var uuid: UUID?
        if let rawUUID = opmlEntry.attributeStringValue("uuid") {
            uuid = UUID(uuidString: rawUUID)
        }
        if let minimumVersion = opmlEntry.attributeStringValue("minAppVersion"),
           !Self.isCurrentAppVersionAtLeast(minimumVersion) {
            return (importedCategories, importedDirectories, importedFeeds, importedScripts)
        }
        precondition(realm.isInWriteTransaction)

        if opmlEntry.feedURL != nil {
            if let uuid = uuid, let feed = realm.object(ofType: Feed.self, forPrimaryKey: uuid) {
                let feedCategory = feed.getCategory()
                let feedURLChangedInManagedOPML = opmlEntry.feedURL.map { feed.rssUrl != $0 } == true
                    && downloadURL.map { LibraryConfiguration.opmlURLs.contains($0) } == true
                if feedCategory == nil || feedCategory?.opmlURL == downloadURL || feed.isDeleted || feedURLChangedInManagedOPML {
                    if feedURLChangedInManagedOPML,
                       feed.title.localizedCaseInsensitiveContains("niponica")
                        || feed.rssUrl.absoluteString.localizedCaseInsensitiveContains("niponica")
                        || (opmlEntry.feedURL?.absoluteString.localizedCaseInsensitiveContains("niponica") ?? false) {
                        debugPrint(
                            "# NIPONICA stage=library.opml.feed.reconcileManagedURL",
                            "feedID=\(feed.id.uuidString)",
                            "title=\(feed.title)",
                            "oldRSSURL=\(feed.rssUrl.absoluteString)",
                            "newRSSURL=\(opmlEntry.feedURL?.absoluteString ?? "nil")",
                            "categoryID=\(feedCategory?.id.uuidString ?? "nil")",
                            "categoryOpmlURL=\(feedCategory?.opmlURL?.absoluteString ?? "nil")",
                            "downloadURL=\(downloadURL?.absoluteString ?? "nil")"
                        )
                    }
                    if Self.hasChanges(opml: opml, opmlEntry: opmlEntry, feed: feed, categoryID: categoryID, directoryID: directoryID, ordinal: ordinal) {
                        try Task.checkCancellation()
                        let categoryID = categoryID ?? feedCategory?.id
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, feed: feed, categoryID: categoryID, directoryID: directoryID, ordinal: ordinal, at: timestamp)
                    }
                    importedFeeds.append(feed)
                }
            } else if opmlEntry.feedURL != nil {
                let feed = Feed()
                if let uuid = uuid, feed.realm == nil {
                    feed.id = uuid
                    try Task.checkCancellation()
                    try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, feed: feed, categoryID: categoryID, directoryID: directoryID, ordinal: ordinal, at: timestamp)
                    realm.add(feed, update: .modified)
                    feed.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                    importedFeeds.append(feed)
                }
            }
        } else if opmlEntry.attributeStringValue("script") != nil {
            if let uuid = uuid, let script = realm.objects(UserScript.self).filter({ $0.id == uuid }).first {
                if script.opmlURL == downloadURL || script.isDeleted {
                    if Self.hasChanges(opml: opml, opmlEntry: opmlEntry, script: script) {
                        try Task.checkCancellation()
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, script: script, at: timestamp)
                        try Self.applyScriptDomains(opml: opml, opmlEntry: opmlEntry, script: script, at: timestamp)
                    }
                    importedScripts.append(script)
                }
            } else {
                let script = UserScript()
                if let uuid = uuid, script.realm == nil {
                    script.id = uuid
                    if let downloadURL = downloadURL {
                        script.opmlURL = downloadURL
                    }
                    try Task.checkCancellation()
                    try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, script: script, at: timestamp)
                    realm.add(script, update: .modified)
                    script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                    try Self.applyScriptDomains(opml: opml, opmlEntry: opmlEntry, script: script, at: timestamp)
                    importedScripts.append(script)
                }
            }
        } else if uuid != nil || !(opmlEntry.children?.isEmpty ?? true) {
//            let opmlTitle = opmlEntry.title ?? opmlEntry.text
            if category == nil, !(opmlEntry.attributes?.contains(where: { $0.name == "isUserScriptList" }) ?? false) {
                if let uuid, let existingCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: uuid) {
                    category = existingCategory
                    let hasChanges = Self.hasChanges(opml: opml, opmlEntry: opmlEntry, category: existingCategory, downloadURL: downloadURL)
                    if hasChanges {
                        //                        if existingCategory.opmlURL == downloadURL || existingCategory.isDeleted {
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, category: existingCategory, downloadURL: downloadURL, at: timestamp)
                    }
                    importedCategories.append(existingCategory)
                    //                        }
                } else if let uuid = uuid {
                    category = FeedCategory()
                    if let category = category {
                        category.id = uuid
                        if let downloadURL = downloadURL {
                            category.opmlURL = downloadURL
                        }
                        try Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, category: category, downloadURL: downloadURL, at: timestamp)
                        realm.add(category, update: .modified)
                        category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        importedCategories.append(category)
                    }
                }
            } else if category != nil, !(opmlEntry.attributes?.contains(where: { $0.name == "isUserScriptList" }) ?? false) {
                if let uuid, let existingDirectory = realm.object(ofType: FeedDirectory.self, forPrimaryKey: uuid) {
                    directory = existingDirectory
                    if Self.hasChanges(opml: opml, opmlEntry: opmlEntry, directory: existingDirectory, categoryID: categoryID, parentDirectoryID: directoryID, ordinal: ordinal) {
                        try Self.applyAttributes(
                            opml: opml,
                            opmlEntry: opmlEntry,
                            directory: existingDirectory,
                            categoryID: categoryID,
                            parentDirectoryID: directoryID,
                            ordinal: ordinal,
                            downloadURL: downloadURL,
                            at: timestamp
                        )
                    }
                    importedDirectories.append(existingDirectory)
                } else if let uuid {
                    directory = FeedDirectory()
                    if let directory {
                        directory.id = uuid
                        try Self.applyAttributes(
                            opml: opml,
                            opmlEntry: opmlEntry,
                            directory: directory,
                            categoryID: categoryID,
                            parentDirectoryID: directoryID,
                            ordinal: ordinal,
                            downloadURL: downloadURL,
                            at: timestamp
                        )
                        realm.add(directory, update: .modified)
                        directory.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        importedDirectories.append(directory)
                    }
                }
            }
        }
        
        for (childIndex, childEntry) in (opmlEntry.children ?? []).enumerated() {
            try Task.checkCancellation()
            let (newCategories, newDirectories, newFeeds, newScripts) = try applyOPMLEntry(
                childEntry,
                opml: opml,
                downloadURL: downloadURL,
                category: category,
                directory: directory,
                ordinal: childIndex,
                in: realm,
                at: timestamp,
                importedCategories: importedCategories,
                importedDirectories: importedDirectories,
                importedFeeds: importedFeeds,
                importedScripts: importedScripts
            )
            importedCategories.append(contentsOf: newCategories)
            importedDirectories.append(contentsOf: newDirectories)
            importedFeeds.append(contentsOf: newFeeds)
            importedScripts.append(contentsOf: newScripts)
        }
        return (importedCategories, importedDirectories, importedFeeds, importedScripts)
    }

    static func isCurrentAppVersionAtLeast(_ minimumVersion: String) -> Bool {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return false
        }
        return compareVersion(currentVersion, minimumVersion) != .orderedAscending
    }

    static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftComponents = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rightComponents = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(leftComponents.count, rightComponents.count) {
            let left = index < leftComponents.count ? leftComponents[index] : 0
            let right = index < rightComponents.count ? rightComponents[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
    
    static func applyScriptDomains(opml: OPML, opmlEntry: OPMLEntry, script: UserScript, at timestamp: Date = Date()) throws {
        guard let realm = script.realm else { return }
        let domains: [String] = opmlEntry.attributeStringValue("allowedDomains")?.split(separator: ",").compactMap { $0.removingPercentEncoding } ?? []
//        script.allowedDomains.removeAll()
        let allowedDomainIDs = Array(script.allowedDomainIDs)
        var didChangeScript = false
        for existingDomainID in allowedDomainIDs {
            guard let index = script.allowedDomainIDs.index(of: existingDomainID) else { continue }
            guard let existingDomain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: existingDomainID) else {
                script.allowedDomainIDs.remove(at: index)
                didChangeScript = true
                continue
            }
            if !domains.contains(existingDomain.domain) {
                if !existingDomain.isDeleted {
                    existingDomain.isDeleted = true
                    existingDomain.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                script.allowedDomainIDs.remove(at: index)
                didChangeScript = true
            } else if existingDomain.isDeleted {
                existingDomain.isDeleted = false
                existingDomain.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            }
        }
        let existingDomains = script.getAllowedDomains()?.map { $0.domain } ?? []
        for domain in domains {
            if !existingDomains.contains(domain) {
                let newDomain = UserScriptAllowedDomain()
                newDomain.domain = domain
                realm.add(newDomain, update: .modified)
                newDomain.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                script.allowedDomainIDs.append(newDomain.id)
                didChangeScript = true
            }
        }
        if didChangeScript {
            script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
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
        let newIsArchived = opmlEntry.attributeBoolValue("isArchived") ?? false
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
        return false
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, script: UserScript, at timestamp: Date = Date()) throws {
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
        let newIsArchived = opmlEntry.attributeBoolValue("isArchived") ?? false
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
        
        if didChange {
            script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
        }
    }
    
    static func hasChanges(opml: OPML, opmlEntry: OPMLEntry, category: FeedCategory, downloadURL: URL? = nil) -> Bool {
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
        if let downloadURL, category.opmlURL != downloadURL {
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
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, category: FeedCategory, downloadURL: URL? = nil, at timestamp: Date = Date()) throws {
        // Must be kept in sync with the respective hasChanges
        var didChange = false
        
        let newBackgroundImageURL = opmlEntry.attributeStringValue("backgroundImageUrl")
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        let oldTitle = category.title
        let oldBackgroundImageURL = category.backgroundImageUrl.absoluteString
        let oldOpmlOwnerName = category.opmlOwnerName
        let oldIsDeleted = category.isDeleted
        let oldIsArchived = category.isArchived
        
        if category.title != newOpmlTitle {
            category.title = newOpmlTitle
            didChange = true
        }
        let newOpmlOwnerName = opml.ownerName ?? category.opmlOwnerName
        if category.opmlOwnerName != newOpmlOwnerName {
            category.opmlOwnerName = newOpmlOwnerName
            didChange = true
        }
        if let downloadURL, category.opmlURL != downloadURL {
            category.opmlURL = downloadURL
            didChange = true
        }
        if let newBackgroundImageURL = newBackgroundImageURL, let newURL = URL(string: newBackgroundImageURL), category.backgroundImageUrl != newURL {
            category.backgroundImageUrl = newURL
            didChange = true
        } else if let newBackgroundImageURL, URL(string: newBackgroundImageURL) == nil {
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
            category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
        }
    }

    static func hasChanges(opml: OPML, opmlEntry: OPMLEntry, directory: FeedDirectory, categoryID: UUID?, parentDirectoryID: UUID?, ordinal: Int? = nil) -> Bool {
        if opmlEntry.attributeUUIDValue("uuid") != directory.id {
            return true
        }
        if directory.categoryID != categoryID {
            return true
        }
        if directory.parentDirectoryID != parentDirectoryID {
            return true
        }
        if directory.ordinal != ordinal {
            return true
        }
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        if directory.title != newOpmlTitle {
            return true
        }
        let newMarkdownDescription = opmlEntry.attributeStringValue("markdownDescription") ?? directory.markdownDescription
        if directory.markdownDescription != newMarkdownDescription {
            return true
        }
        let newOpmlOwnerName = opml.ownerName ?? directory.opmlOwnerName
        if directory.opmlOwnerName != newOpmlOwnerName {
            return true
        }
        let newIconURL = opmlEntry.attributeStringValue("iconUrl").flatMap(URL.init(string:))
        if let newIconURL, directory.iconUrl != newIconURL {
            return true
        }
        let newBackgroundImageURL = opmlEntry.attributeStringValue("backgroundImageUrl").flatMap(URL.init(string:))
        if let newBackgroundImageURL, directory.backgroundImageUrl != newBackgroundImageURL {
            return true
        }
        if directory.isDeleted {
            return true
        }
        if opmlEntry.attributeBoolValue("isCommented") ?? false {
            if !directory.isArchived {
                return true
            }
        } else if directory.isArchived {
            return true
        }
        return false
    }

    static func applyAttributes(
        opml: OPML,
        opmlEntry: OPMLEntry,
        directory: FeedDirectory,
        categoryID: UUID?,
        parentDirectoryID: UUID?,
        ordinal: Int? = nil,
        downloadURL: URL?,
        at timestamp: Date = Date()
    ) throws {
        var didChange = false

        if directory.categoryID != categoryID {
            directory.categoryID = categoryID
            didChange = true
        }
        if directory.parentDirectoryID != parentDirectoryID {
            directory.parentDirectoryID = parentDirectoryID
            didChange = true
        }
        if directory.ordinal != ordinal {
            directory.ordinal = ordinal
            didChange = true
        }
        let newOpmlTitle = opmlEntry.title ?? opmlEntry.text
        if directory.title != newOpmlTitle {
            directory.title = newOpmlTitle
            didChange = true
        }
        let newMarkdownDescription = opmlEntry.attributeStringValue("markdownDescription") ?? directory.markdownDescription
        if directory.markdownDescription != newMarkdownDescription {
            directory.markdownDescription = newMarkdownDescription
            didChange = true
        }
        let newOpmlOwnerName = opml.ownerName ?? directory.opmlOwnerName
        if directory.opmlOwnerName != newOpmlOwnerName {
            directory.opmlOwnerName = newOpmlOwnerName
            didChange = true
        }
        if directory.opmlURL != downloadURL {
            directory.opmlURL = downloadURL
            didChange = true
        }
        if let newIconURL = opmlEntry.attributeStringValue("iconUrl").flatMap(URL.init(string:)), directory.iconUrl != newIconURL {
            directory.iconUrl = newIconURL
            didChange = true
        }
        if let newBackgroundImageURL = opmlEntry.attributeStringValue("backgroundImageUrl").flatMap(URL.init(string:)), directory.backgroundImageUrl != newBackgroundImageURL {
            directory.backgroundImageUrl = newBackgroundImageURL
            didChange = true
        }
        if directory.isDeleted {
            directory.isDeleted = false
            didChange = true
        }
        if opmlEntry.attributeBoolValue("isCommented") ?? false {
            if !directory.isArchived {
                directory.isArchived = true
                didChange = true
            }
        } else if directory.isArchived {
            directory.isArchived = false
            didChange = true
        }

        if didChange {
            directory.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
        }
    }
    
    static func hasChanges(opml: OPML, opmlEntry: OPMLEntry, feed: Feed, categoryID: UUID?, directoryID: UUID?, ordinal: Int? = nil) -> Bool {
        guard let feedURL = opmlEntry.feedURL else { return false }
        if feed.categoryID != categoryID {
            return true
        }
        if feed.directoryID != directoryID {
            return true
        }
        if feed.ordinal != ordinal {
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
        let newEntryContentKind = ReaderContentKind(rawValue: opmlEntry.attributeStringValue("entryContentKind") ?? "") ?? .readerContent
        if feed.entryContentKind != newEntryContentKind {
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
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, feed: Feed, categoryID: UUID?, directoryID: UUID?, ordinal: Int? = nil, at timestamp: Date = Date()) throws {
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
        if feed.directoryID != directoryID {
            feed.directoryID = directoryID
            didChange = true
        }
        if feed.ordinal != ordinal {
            feed.ordinal = ordinal
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
            feed.lastFetchedETag = nil
            feed.lastFetchedModifiedAt = nil
            feed.lastRefreshedEntriesAt = nil
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
        let newEntryContentKind = ReaderContentKind(rawValue: opmlEntry.attributeStringValue("entryContentKind") ?? "") ?? .readerContent
        if feed.entryContentKind != newEntryContentKind {
            feed.entryContentKind = newEntryContentKind
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
            feed.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
        }
    }
    
    @RealmBackgroundActor
    public func exportUserOPML(
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) async throws -> OPML {
        let configuration = try await LibraryConfiguration.getConsolidatedOrCreate(
            realmConfiguration: realmConfiguration
        )
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
        
        func exportFeed(_ feed: Feed) -> OPMLEntry {
            var attributes = [
                Attribute(name: "uuid", value: feed.id.uuidString),
                Attribute(name: "type", value: "rss"),
                Attribute(name: "xmlUrl", value: feed.rssUrl.absoluteString),
                Attribute(name: "extractImageFromContent", value: feed.extractImageFromContent ? "true" : "false"),
                Attribute(name: "isReaderModeByDefault", value: feed.isReaderModeByDefault ? "true" : "false"),
                Attribute(name: "iconUrl", value: feed.iconUrl.absoluteString),
            ]
            if let markdownDescription = feed.markdownDescription, !markdownDescription.isEmpty {
                attributes.append(Attribute(name: "markdownDescription", value: markdownDescription))
            }
            attributes.append(Attribute(name: "rssContainsFullContent", value: feed.rssContainsFullContent ? "true" : "false"))
            attributes.append(Attribute(name: "injectEntryImageIntoHeader", value: feed.injectEntryImageIntoHeader ? "true" : "false"))
            attributes.append(Attribute(name: "displayPublicationDate", value: feed.displayPublicationDate ? "true" : "false"))
            attributes.append(Attribute(name: "meaningfulContentMinLength", value: String(feed.meaningfulContentMinLength)))
            return OPMLEntry(
                text: feed.title,
                title: feed.title,
                attributes: attributes
            )
        }
        func exportChildren(_ children: [FeedCollectionChild], ancestors: Set<UUID> = []) throws -> [OPMLEntry] {
            try children.compactMap { child in
                try Task.checkCancellation()
                switch child {
                case .feed(let feed):
                    guard !feed.isArchived else { return nil }
                    return exportFeed(feed)
                case .directory(let directory):
                    guard !directory.isArchived, !ancestors.contains(directory.id) else { return nil }
                    return OPMLEntry(
                        text: directory.title,
                        attributes: [Attribute(name: "uuid", value: directory.id.uuidString)],
                        children: try exportChildren(
                            directory.getCollectionChildren() ?? [],
                            ancestors: ancestors.union([directory.id])
                        )
                    )
                }
            }
        }

        let categoryEntries: [OPMLEntry] = try userCategories.map { category in
            try Task.checkCancellation()
            return OPMLEntry(
                text: category.title,
                attributes: [
                    Attribute(name: "uuid", value: category.id.uuidString),
                    Attribute(name: "backgroundImageUrl", value: category.backgroundImageUrl.absoluteString),
                    Attribute(name: "isFeedCategory", value: "true"),
                ],
                children: try exportChildren(category.getCollectionChildren() ?? [])
            )
        }

        let opml = OPML(
            dateModified: Date(),
            ownerName: (Self.currentUsername?.isEmpty ?? true) ? nil : Self.currentUsername,
            entries: [scriptEntries] + categoryEntries
        )
        return opml
    }
}
