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

let bookmarksQueue = DispatchQueue(label: "BookmarksQueue")

@MainActor
fileprivate class BookmarkButtonViewModel: ObservableObject {
    @Published var reloadTrigger = ""
    //    var readerContentHTML: String?
    var readerContent: (any ReaderContentProtocol)? {
        didSet {
            Task { @MainActor in
                try await refresh()
            }
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
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
            realm.objects(Bookmark.self)
                .collectionPublisher(keyPaths: ["isDeleted", "compoundKey"])
                .subscribe(on: bookmarksQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.2), scheduler: bookmarksQueue)
                .receive(on: bookmarksQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        try await self?.refresh()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    @MainActor
    private func refresh() async throws {
        guard let readerContent = readerContent else {
            self.bookmarkExists = false
            return
        }
        let bookmarkExists = await readerContent.bookmarkExists(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
        self.bookmarkExists = bookmarkExists
        self.forceShowBookmark = false
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
            Label(configuration.isOn ? "Saved for Later" : "Save for Later", systemImage: configuration.isOn ? "bookmark.fill" : "bookmark")
        }
        .controlSize(.small)
        .buttonStyle(.clearBordered)
    }
}

// MARK: - BookmarkButton

public struct BookmarkButton<C: ReaderContentProtocol>: View {
    var readerContent: C
    var hiddenIfUnbookmarked = false
    
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var viewModel = BookmarkButtonViewModel()
    
    private var showBookmarkExists: Bool {
        isEnabled && (viewModel.bookmarkExists || viewModel.forceShowBookmark)
    }
    
    private var isBookmarkedBinding: Binding<Bool> {
        Binding(
            get: { showBookmarkExists },
            set: { newValue in
                Task { @MainActor in
                    // Only toggle if the requested state differs from what is currently shown
                    if newValue != showBookmarkExists {
                        viewModel.forceShowBookmark = try await readerContent.toggleBookmark(
                            realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration
                        )
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
        .onChange(of: readerContent) { _ in
            Task { @MainActor in
                viewModel.forceShowBookmark = false
                viewModel.readerContent = nil
            }
        }
        .task(id: readerContent) { @MainActor in
            viewModel.readerContent = readerContent
        }
    }
    
    public init(readerContent: C, hiddenIfUnbookmarked: Bool = false) {
        self.readerContent = readerContent
        self.hiddenIfUnbookmarked = hiddenIfUnbookmarked
    }
}
