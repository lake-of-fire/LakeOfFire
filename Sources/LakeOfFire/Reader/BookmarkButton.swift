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
    var readerContent: (any ReaderContentModel)? {
        didSet {
            refresh()
        }
    }
    
    @Published var bookmarkToggle = false {
        didSet {
            guard let readerContent = readerContent else { return }
            Task {
                if bookmarkToggle {
                    try await readerContent.addBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                } else {
                    try await _ = readerContent.removeBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                }
            }
        }
    }
    @Published var bookmark: Bookmark? {
        didSet {
            refresh()
        }
    }
    
    @RealmBackgroundActor var cancellables = Set<AnyCancellable>()
    
    init() {
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration, actor: RealmBackgroundActor.shared)
            realm.objects(Bookmark.self)
                .collectionPublisher(keyPaths: ["isDeleted", "compoundKey"])
                .removeDuplicates()
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { [weak self] in
                        await self?.refresh()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    private func refresh() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let readerContent = readerContent else { return }
            let realm = try await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration)
            let bookmark = realm.objects(Bookmark.self).where({
                $0.compoundKey == Bookmark.makePrimaryKey(url: readerContent.url, html: readerContent.html) ?? "" }).first
            self.bookmark = bookmark
            
            bookmarkToggle = bookmark?.isDeleted ?? true
        }
    }
}

public struct BookmarkButton: View {
    var readerContent: (any ReaderContentModel)
    @Binding var readerWebViewState: WebViewState
    @ObservedResults(Bookmark.self, keyPaths: ["isDeleted", "compoundKey"]) var bookmarks
    
    @StateObject private var viewModel = BookmarkButtonViewModel()
    
    public var body: some View {
//        BookmarkButtonToggle(bookmark: readerContent?.bookmark ?? Bookmark())
        Toggle(isOn: $viewModel.bookmarkToggle) {
            if viewModel.bookmarkToggle {
                Label("Saved for Later", systemImage: "bookmark.fill")
            } else {
                Label("Save for Later", systemImage: "bookmark")
            }
//            Text(bookmark.url?.absoluteString ?? "...")
//            Text("\(bookmark.html?.count ?? -1)")
        }
        .disabled(readerWebViewState.isProvisionallyNavigating || readerWebViewState.pageURL.isNativeReaderView)
        .toggleStyle(.button)
        .fixedSize()
        .task { @MainActor in
            viewModel.readerContent = readerContent
        }
        .onChange(of: bookmarks) { _ in
            refreshBookmark()
        }
//        .id(readerContent.compoundKey)
    }
    
    public init(readerContent: (any ReaderContentModel), readerState: Binding<WebViewState>) {
        self.readerContent = readerContent
        _readerWebViewState = readerState
    }
    
    private func refreshBookmark() {
        Task { @MainActor in
        }
    }
}
