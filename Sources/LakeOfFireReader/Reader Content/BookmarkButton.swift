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

struct BookmarkActionPresentation {
    struct Request: Equatable {
        let id: UUID
        let contentKey: String
    }

    private var current: Request?
    private(set) var failure: Request?

    mutating func begin(contentKey: String) -> Request {
        let request = Request(id: UUID(), contentKey: contentKey)
        current = request
        failure = nil
        return request
    }

    @discardableResult
    mutating func recordFailure(
        _ error: Error, for request: Request, currentContentKey: String?
    ) -> Bool {
        guard !(error is CancellationError),
              current == request,
              request.contentKey == currentContentKey else { return false }
        failure = request
        return true
    }

    mutating func acknowledge(_ request: Request) {
        guard failure == request else { return }
        failure = nil
    }

    mutating func retire() {
        current = nil
        failure = nil
    }
}

public struct BookmarkButton<C: ReaderContentProtocol>: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    let iconOnly: Bool
    var readerContent: C
    var hiddenIfUnbookmarked = false
    
    @Environment(\.isEnabled) private var isEnabled
    @State private var actionPresentation = BookmarkActionPresentation()
    @ObservedObject private var bookmarkStatusCache = BookmarkStatusCache.shared
    
    private var showBookmarkExists: Bool {
        return isEnabled && bookmarkStatusCache.isBookmarked(readerContent)
    }

    private var actionContentKey: String? {
        guard isEnabled, !readerContent.isInvalidated else { return nil }
        return readerContent.compoundKey
    }
    
    public var body: some View {
        let presentedFailure = actionPresentation.failure
        let presentsFailure = Binding(
            get: {
                guard let presentedFailure else { return false }
                return actionPresentation.failure == presentedFailure
                    && presentedFailure.contentKey == actionContentKey
            },
            set: { isPresented in
                if !isPresented, let presentedFailure {
                    actionPresentation.acknowledge(presentedFailure)
                }
            }
        )
        Button {
            guard let actionContentKey else { return }
            let request = actionPresentation.begin(contentKey: actionContentKey)
            Task { @MainActor in
                guard !readerContent.isInvalidated else { return }
                do {
                    // Realm observation owns the label, including when a later
                    // toggle changes the status during the history follow-up.
                    _ = try await readerContent.toggleBookmark(
                        realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    actionPresentation.recordFailure(
                        error, for: request, currentContentKey: self.actionContentKey
                    )
                }
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
        .alert("Couldn’t Finish Updating Save for Later", isPresented: presentsFailure) {
            Button("OK") {
                if let presentedFailure { actionPresentation.acknowledge(presentedFailure) }
            }
        } message: {
            Text("Check whether this page is saved before changing its bookmark again.")
        }
        .onChange(of: actionContentKey) { _ in actionPresentation.retire() }
        .onDisappear { actionPresentation.retire() }
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
        if let content = readerContent.content, !content.isInvalidated {
            AnyView(content.bookmarkButtonView(width: width, height: height, iconOnly: iconOnly))
                .id(content.compoundKey)
                .disabled(readerContent.isReaderProvisionallyNavigating || readerContent.pageURL.isNativeReaderView)
        }
    }
    
    public init(width: CGFloat? = nil, height: CGFloat? = nil, iconOnly: Bool) {
        self.width = width
        self.height = height
        self.iconOnly = iconOnly
    }
}
