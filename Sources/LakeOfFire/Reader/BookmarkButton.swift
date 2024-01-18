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

@MainActor
fileprivate class BookmarkButtonViewModel: ObservableObject {
    @Published var reloadTrigger = ""
//    var readerContentHTML: String?
    var readerContent: (any ReaderContentModel)? {
        didSet {
            refresh()
        }
    }
//    
//    @Published var bookmarkToggle = false {
//        didSet {
//            let realm = try await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration, actor: RealmBackgroundActor.shared)
//            Task { @MainActor [weak self] in
//                guard let self = self else { return }
//                if bookmarkToggle {
//                    try await readerContent.addBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
//                } else {
//                    try await _ = readerContent.removeBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
//                }
//            }
//        }
//    }
//    @Published var bookmark: Bookmark? {
//        didSet {
//            refresh()
//        }
//    }
    
    @Published var bookmarkExists = false
    @Published var forceShowBookmark = false
    
    @RealmBackgroundActor var cancellables = Set<AnyCancellable>()
    
    init() {
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration, actor: RealmBackgroundActor.shared)
            realm.objects(Bookmark.self)
                .collectionPublisher(keyPaths: ["isDeleted", "compoundKey"])
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refresh()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    private func refresh() {
        guard let readerContent = readerContent else {
            Task { @MainActor in
                self.bookmarkExists = false
            }
            return
        }
        let bookmarkExists = readerContent.bookmarkExists(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
        Task { @MainActor in
            self.bookmarkExists = bookmarkExists
            self.forceShowBookmark = false
        }
//
//        Task { @MainActor [weak self] in
//            guard let self = self else { return }
//            guard let readerContent = readerContent, !readerContent.url.isNativeReaderView else {
//                if bookmark != nil {
//                    bookmark = nil
//                }
//                return
//            }
//            let realm = try await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration)
//            let bookmark = realm.objects(Bookmark.self).where({
//                $0.compoundKey == Bookmark.makePrimaryKey(url: readerContent.url, html: readerContent.html) ?? "" }).first
//            if self.bookmark?.compoundKey != bookmark?.compoundKey {
//                self.bookmark = bookmark
//            }
//            
//            bookmarkToggle = !(bookmark?.isDeleted ?? true)
//        }
    }
}

public struct BookmarkButton<C: ReaderContentModel>: View {
    var readerContent: C
    var hiddenIfUnbookmarked = false
    
    @Environment(\.isEnabled) private var isEnabled

    @ObservedResults(Bookmark.self, keyPaths: ["isDeleted", "compoundKey"]) var bookmarks
    
    @StateObject private var viewModel = BookmarkButtonViewModel()
    
    private var showBookmarkExists: Bool {
        return isEnabled && (viewModel.bookmarkExists || viewModel.forceShowBookmark)
    }
    
    public var body: some View {
        Button {
            Task { @MainActor in
                viewModel.forceShowBookmark = try await readerContent.toggleBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
            }
        } label: {
            Label(showBookmarkExists ? "Saved for Later" : "Save for Later", systemImage: showBookmarkExists ? "bookmark.fill" : "bookmark")
                .padding(.horizontal, 4)
        }
//        .buttonStyle(.borderless)
//        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .opacity(hiddenIfUnbookmarked ? (showBookmarkExists ? 1 : 0) : 1)
        .allowsHitTesting(hiddenIfUnbookmarked ? showBookmarkExists : true)
//        .fixedSize()
        .onChange(of: readerContent) { readerContent in
            Task { @MainActor in
                viewModel.forceShowBookmark = false
                viewModel.readerContent = nil
            }
        }
        .task(id: readerContent) {
            viewModel.readerContent = readerContent
        }
    }
    
    public init(readerContent: C, hiddenIfUnbookmarked: Bool = false) {
        self.readerContent = readerContent
        self.hiddenIfUnbookmarked = hiddenIfUnbookmarked
    }
}

public extension ReaderContentModel {
    var bookmarkButtonView: some View {
        BookmarkButton(readerContent: self)
    }
}

public struct CurrentWebViewBookmarkButton: View {
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @Environment(\.readerWebViewState) private var readerWebViewState
    
    public var body: some View {
        AnyView(readerViewModel.content.bookmarkButtonView)
            .disabled(readerWebViewState.isProvisionallyNavigating || readerWebViewState.pageURL.isNativeReaderView)
    }
    
    public init() { }
}
