import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContent
import LakeOfFireCore
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

let bookmarksQueue = DispatchQueue(label: "BookmarksQueue")

public final class BookmarkStatusCache: ObservableObject {
    public static let shared = BookmarkStatusCache()

    @Published private var bookmarkedCompoundKeys: Set<String> = []

    @RealmBackgroundActor private var cancellables = Set<AnyCancellable>()
    private var hasStartedObservation = false

    init() { }

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
                    .map { @Sendable _ in }
                    .debounceLeadingTrailing(for: .seconds(0.2), scheduler: bookmarksQueue)
                    .receive(on: bookmarksQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @RealmBackgroundActor [weak self] in
                            guard let self else { return }
                            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
                            await self.refresh(from: realm)
                        }
                    })
                    .store(in: &cancellables)
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
            guard let self, bookmarkedCompoundKeys != keys else { return }
            bookmarkedCompoundKeys = keys
        }
    }

    private func bookmarkKey(for readerContent: any ReaderContentProtocol) -> String? {
        let url = readerContent.url
        // URL-backed content does not need HTML decompression for a status read.
        let usesHTML = url.absoluteString.hasPrefix("about:")
            || url.absoluteString.hasPrefix("internal://local")
        return Bookmark.makePrimaryKey(url: url, html: usesHTML ? readerContent.html : nil)
    }

    public func isBookmarked(_ readerContent: any ReaderContentProtocol) -> Bool {
        guard !readerContent.isInvalidated,
              let key = bookmarkKey(for: readerContent) else { return false }
        return bookmarkedCompoundKeys.contains(key)
    }

    public func setIsBookmarked(_ isBookmarked: Bool, for readerContent: any ReaderContentProtocol) {
        guard !readerContent.isInvalidated,
              let key = bookmarkKey(for: readerContent) else { return }
        setIsBookmarked(isBookmarked, forCompoundKey: key)
    }

    public func setIsBookmarked(_ isBookmarked: Bool, forCompoundKey compoundKey: String) {
        guard bookmarkedCompoundKeys.contains(compoundKey) != isBookmarked else {
            return
        }
        if isBookmarked {
            bookmarkedCompoundKeys.insert(compoundKey)
        } else {
            bookmarkedCompoundKeys.remove(compoundKey)
        }
    }
}

public struct BookmarkButton<C: ReaderContentProtocol>: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    let iconOnly: Bool
    var readerContent: C
    var hiddenIfUnbookmarked = false
    
    @Environment(\.isEnabled) private var isEnabled
    
    @ObservedObject private var bookmarkStatusCache = BookmarkStatusCache.shared
    
    private var showBookmarkExists: Bool {
        return isEnabled && bookmarkStatusCache.isBookmarked(readerContent)
    }
    
    public var body: some View {
        Button {
            Task { @MainActor in
                guard !readerContent.isInvalidated, !readerContent.isDeleted else { return }
                guard let bookmarkKey = Bookmark.makePrimaryKey(url: readerContent.url, html: readerContent.html) else { return }
                let isBookmarked = try await readerContent.toggleBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                bookmarkStatusCache.setIsBookmarked(isBookmarked, forCompoundKey: bookmarkKey)
            }
        } label: {
            BookmarkMenuLabel(isBookmarked: showBookmarkExists)
            //                .padding(.horizontal, 4)
            //                .padding(.vertical, 2)
                .background(.secondary.opacity(0.000000001)) // clickability
                .frame(width: width, height: height)
        }
        //        .buttonStyle(.borderless)
        //        .buttonStyle(.plain)
        .modifier {
            if iconOnly {
                $0.labelStyle(.iconOnly)
            } else { $0 }
        }
        .accessibilityIdentifier("ReaderBookmark.Toggle")
        .opacity(hiddenIfUnbookmarked ? (showBookmarkExists ? 1 : 0) : 1)
        .allowsHitTesting(hiddenIfUnbookmarked ? showBookmarkExists : true)
        .task { @MainActor in
            bookmarkStatusCache.startIfNeeded()
        }
    }
    
    public init(width: CGFloat? = nil, height: CGFloat? = nil, iconOnly: Bool, readerContent: C, hiddenIfUnbookmarked: Bool = false) {
        self.width = width
        self.height = height
        self.iconOnly = iconOnly
        self.readerContent = readerContent
        self.hiddenIfUnbookmarked = hiddenIfUnbookmarked
    }
}

public extension ReaderContentProtocol {
    @ViewBuilder func bookmarkButtonView(width: CGFloat? = nil, height: CGFloat? = nil, iconOnly: Bool) -> some View {
        BookmarkButton(width: width, height: height, iconOnly: iconOnly, readerContent: self)
    }
}

public struct CurrentWebViewBookmarkButton: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    
    let iconOnly: Bool
    @EnvironmentObject private var readerContent: ReaderContent
    
    public var body: some View {
        if let content = readerContent.content {
            AnyView(content.bookmarkButtonView(width: width, height: height, iconOnly: iconOnly))
                .disabled(readerContent.isReaderProvisionallyNavigating || readerContent.pageURL.isNativeReaderView)
        }
    }
    
    public init(width: CGFloat? = nil, height: CGFloat? = nil, iconOnly: Bool) {
        self.width = width
        self.height = height
        self.iconOnly = iconOnly
    }
}
