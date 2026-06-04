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
                let isBookmarked = try await readerContent.toggleBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                bookmarkStatusCache.setIsBookmarked(isBookmarked, for: readerContent)
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
