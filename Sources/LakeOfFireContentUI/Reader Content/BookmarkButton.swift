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

    private init() { }

    func startIfNeeded() {
        guard !hasStartedObservation else { return }
        hasStartedObservation = true
        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
                await self.refresh(from: realm)
                realm.objects(Bookmark.self)
                    .collectionPublisher(keyPaths: ["isDeleted", "compoundKey"])
                    .subscribe(on: bookmarksQueue)
                    .map { _ in }
                    .debounceLeadingTrailing(for: .seconds(0.2), scheduler: bookmarksQueue)
                    .receive(on: bookmarksQueue)
                    .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                        Task { @RealmBackgroundActor [weak self] in
                            guard let self else { return }
                            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
                            await self.refresh(from: realm)
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

    @RealmBackgroundActor
    private func refresh(from realm: Realm) async {
        let keys = Set(realm.objects(Bookmark.self).where { !$0.isDeleted }.map(\.compoundKey))
        await MainActor.run { [weak self] in
            self?.bookmarkedCompoundKeys = keys
        }
    }

    public func isBookmarked(_ readerContent: any ReaderContentProtocol) -> Bool {
        bookmarkedCompoundKeys.contains(readerContent.compoundKey)
    }

    public func setIsBookmarked(_ isBookmarked: Bool, for readerContent: any ReaderContentProtocol) {
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
                    if newValue != showBookmarkExists {
                        let isBookmarked = try await readerContent.toggleBookmark(
                            realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration
                        )
                        bookmarkStatusCache.setIsBookmarked(isBookmarked, for: readerContent)
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
