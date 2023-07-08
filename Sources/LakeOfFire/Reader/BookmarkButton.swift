//
//  BookmarkButton.swift
//  ManabiReader
//
//  Created by Alex Ehlke on 9/25/22.
//  Copyright © 2022 John A Ehlke. All rights reserved.
//

import Foundation
import SwiftUI
import RealmSwift
import SwiftUIWebView

public struct BookmarkButton: View {
    var readerContent: (any ReaderContentModel)
    @Binding var readerWebViewState: WebViewState
    @ObservedResults(Bookmark.self, keyPaths: ["isDeleted", "compoundKey"]) var bookmarks
    
    @State var bookmark: Bookmark?
    
    public var body: some View {
//        BookmarkButtonToggle(bookmark: readerContent?.bookmark ?? Bookmark())
        Toggle(isOn: Binding(
            get: { !(bookmark?.isDeleted ?? true) },
            set: { isOn in
                if isOn {
                    readerContent.addBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                } else {
                    _ = readerContent.removeBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                }
            }
        )) {
            if bookmark?.isDeleted ?? true {
                Label("Save for Later", systemImage: "bookmark")
            } else {
                Label("Saved for Later", systemImage: "bookmark.fill")
            }
//            Text(bookmark.url?.absoluteString ?? "...")
//            Text("\(bookmark.html?.count ?? -1)")
        }
        .disabled(readerWebViewState.isProvisionallyNavigating || readerWebViewState.pageURL.isNativeReaderView)
        .toggleStyle(.button)
        .fixedSize()
        .task {
            refreshBookmark()
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
            let bookmark = bookmarks.where({ $0.compoundKey == Bookmark.makePrimaryKey(url: readerContent.url, html: readerContent.html) ?? "" }).first
            self.bookmark = bookmark
        }
    }
}
