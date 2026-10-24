//
//  BookmarkButton.swift
//  ManabiReader
//
//  Created by Alex Ehlke on 9/25/22.
//  Copyright © 2022 John A Ehlke. All rights reserved.
//

import SwiftUI
import RealmSwift
import SwiftUIWebView
import RealmSwiftGaps
import Combine
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

let bookmarksQueue = DispatchQueue(label: "BookmarksQueue")

// Holds an actual queried snapshot for deterministic publication-order tests.
// Normal refreshes do not install an observer or suspend at this boundary.
enum BookmarkStatusRefreshObservation {
    @TaskLocal static var afterSnapshot: (@Sendable () async -> Void)? = nil
}

fileprivate struct BookmarkMenuLabel: View {
    let isBookmarked: Bool

    var body: some View {
        if isBookmarked {
            Label("Saved for Later", systemImage: "bookmark.fill")
        } else {
            Label("Save for Later", systemImage: "bookmark")
        }
    }
}

@MainActor
public final class BookmarkStatusCache: ObservableObject {
    public static let shared = BookmarkStatusCache()

    @Published private var bookmarkedCompoundKeys: Set<String> = []

    nonisolated(unsafe) private var cancellables = Set<AnyCancellable>()
    private var hasStartedObservation = false
    private var refreshGeneration: UInt64 = 0

    init() { }

    func startIfNeeded() {
        guard !hasStartedObservation else { return }
        hasStartedObservation = true
        let configuration = ReaderContentLoader.bookmarkRealmConfiguration
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: configuration, storageAdmission: admission
                )
                try await self.refresh(configuration: configuration, storageAdmission: admission)
                realm.objects(Bookmark.self)
                    .collectionPublisher(keyPaths: ["isDeleted", "compoundKey"])
                    .subscribe(on: bookmarksQueue)
                    .map { @Sendable _ in }
                    .debounceLeadingTrailing(for: .seconds(0.2), scheduler: bookmarksQueue)
                    .receive(on: bookmarksQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @RealmBackgroundActor [weak self] in
                            guard let self else { return }
                            try await self.refresh(
                                configuration: configuration, storageAdmission: admission
                            )
                        }
                    })
                    .store(in: &self.cancellables)
            } catch {
                await MainActor.run { [weak self] in
                    self?.hasStartedObservation = false
                }
                print(error)
            }
        }
    }

    /// Reconcile a completed command from current store data. The command's
    /// result can already have been superseded by another committed toggle.
    func refreshAfterMutation(configuration: Realm.Configuration) async {
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        do {
            try await refresh(configuration: configuration, storageAdmission: admission)
        } catch is CancellationError {
            return
        } catch {
            print(error)
        }
    }

    private func refresh(
        configuration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission
    ) async throws {
        // An obsolete observer must not retire a current store's pending read.
        guard !Task.isCancelled,
              storageAdmission.matchesCurrentStorageIdentity({
                  RealmBackgroundActor.shared.realmCacheKey(
                      for: ReaderContentLoader.bookmarkRealmConfiguration
                  )
              }) else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let keys = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: configuration, storageAdmission: storageAdmission
            )
            realm.refresh()
            try Task.checkCancellation()
            let keys = Set(realm.objects(Bookmark.self).where { !$0.isDeleted }.map(\.compoundKey))
            await BookmarkStatusRefreshObservation.afterSnapshot?()
            return keys
        }()
        guard !Task.isCancelled, generation == refreshGeneration,
              storageAdmission.matchesCurrentStorageIdentity({
                  RealmBackgroundActor.shared.realmCacheKey(
                      for: ReaderContentLoader.bookmarkRealmConfiguration
                  )
              }),
              bookmarkedCompoundKeys != keys else { return }
        bookmarkedCompoundKeys = keys
    }

    public func isBookmarked(_ readerContent: any ReaderContentProtocol) -> Bool {
        guard !readerContent.isInvalidated else { return false }
        return bookmarkedCompoundKeys.contains(readerContent.compoundKey)
    }

    public func setIsBookmarked(_ isBookmarked: Bool, for readerContent: any ReaderContentProtocol) {
        guard !readerContent.isInvalidated else { return }
        guard bookmarkedCompoundKeys.contains(readerContent.compoundKey) != isBookmarked else {
            return
        }
        if isBookmarked {
            bookmarkedCompoundKeys.insert(readerContent.compoundKey)
        } else {
            bookmarkedCompoundKeys.remove(readerContent.compoundKey)
        }
    }
}

public extension ReaderContentProtocol {
    @ViewBuilder func bookmarkButtonView() -> some View {
        BookmarkButton(readerContent: self)
    }
}

public struct CurrentWebViewBookmarkButton: View {
    @EnvironmentObject private var readerContent: ReaderContent
    
    public var body: some View {
        if let content = readerContent.content {
            AnyView(content.bookmarkButtonView())
                .disabled(readerContent.isReaderProvisionallyNavigating || readerContent.pageURL.isNativeReaderView)
        }
    }
    
    public init() { }
}

private struct BookmarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            BookmarkMenuLabel(isBookmarked: configuration.isOn)
        }
        .controlSize(.small)
        .buttonStyle(.clearBordered)
        .dynamicTypeSize(.medium)
    }
}

// MARK: - BookmarkButton

public struct BookmarkButton<C: ReaderContentProtocol>: View {
    var readerContent: C
    var hiddenIfUnbookmarked = false
    
    @Environment(\.isEnabled) private var isEnabled
    @ObservedObject private var bookmarkStatusCache = BookmarkStatusCache.shared
    
    private var showBookmarkExists: Bool {
        isEnabled && bookmarkStatusCache.isBookmarked(readerContent)
    }
    
    private var isBookmarkedBinding: Binding<Bool> {
        Binding(
            get: { showBookmarkExists },
            set: { newValue in
                Task { @MainActor in
                    guard !readerContent.isInvalidated else { return }
                    if newValue != showBookmarkExists {
                        // A completed mutation describes its own transaction, not
                        // necessarily the latest state after overlapping commands.
                        let configuration = ReaderContentLoader.bookmarkRealmConfiguration
                        _ = try await readerContent.toggleBookmark(
                            realmConfiguration: configuration
                        )
                        await bookmarkStatusCache.refreshAfterMutation(configuration: configuration)
                    }
                }
            }
        )
    }
    
    public var body: some View {
        Toggle(isOn: isBookmarkedBinding) {
            EmptyView()
        }
        .toggleStyle(BookmarkToggleStyle())
        .opacity(hiddenIfUnbookmarked ? (showBookmarkExists ? 1 : 0) : 1)
        .allowsHitTesting(hiddenIfUnbookmarked ? showBookmarkExists : true)
        .task { @MainActor in
            bookmarkStatusCache.startIfNeeded()
        }
    }
    
    public init(readerContent: C, hiddenIfUnbookmarked: Bool = false) {
        self.readerContent = readerContent
        self.hiddenIfUnbookmarked = hiddenIfUnbookmarked
    }
}
