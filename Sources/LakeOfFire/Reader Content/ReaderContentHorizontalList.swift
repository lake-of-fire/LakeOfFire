import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import Pow
import LakeKit

fileprivate enum ReaderContentHorizontalListLayout {
    static let groupBoxContentInsets = EdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
}

fileprivate struct ReaderContentCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .conditionalEffect(.pushDown, condition: configuration.isPressed)
    }
}

fileprivate struct ReaderContentInnerHorizontalListItem<C: ReaderContentProtocol>: View {
    var content: C
    let includeSource: Bool
    let maxCellHeight: CGFloat
    let customMenuOptions: ((C) -> AnyView)?
    let contentSelection: Binding<String?>
    let onContentSelected: ((C) -> Void)?

    @StateObject private var cloudDriveSyncStatusModel = CloudDriveSyncStatusModel()
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.contentSelectionNavigationHint) private var contentSelectionNavigationHint
    @Environment(\.stackListStyle) private var stackListStyle
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel

    @State private var measuredPhysicalCoverWidth: CGFloat?

    private var baseCardWidth: CGFloat { maxCellHeight * 2.5 }
    private var reservedThumbnailSlotWidth: CGFloat { maxCellHeight }
    private var measuredThumbnailWidth: CGFloat? {
        guard let measuredPhysicalCoverWidth, measuredPhysicalCoverWidth > 0 else { return nil }
        return min(measuredPhysicalCoverWidth, reservedThumbnailSlotWidth)
    }
    private var thumbnailSlackWidth: CGFloat {
        guard let measuredThumbnailWidth else { return 0 }
        return max(0, reservedThumbnailSlotWidth - measuredThumbnailWidth)
    }

    private var cardWidth: CGFloat {
        guard content.isPhysicalMedia, measuredThumbnailWidth != nil else {
            return baseCardWidth
        }
        let collapsedWidth = baseCardWidth - thumbnailSlackWidth
        return min(baseCardWidth, collapsedWidth)
    }

    private var cardHeight: CGFloat {
        maxCellHeight
            + ReaderContentHorizontalListLayout.groupBoxContentInsets.top
            + ReaderContentHorizontalListLayout.groupBoxContentInsets.bottom
    }

    var body: some View {
        Button {
            let selection = content.compoundKey
            contentSelection.wrappedValue = selection
            if let onContentSelected {
                onContentSelected(content)
                Task { @MainActor in
                    if contentSelection.wrappedValue == selection {
                        contentSelection.wrappedValue = nil
                    }
                }
                return
            }
            guard !content.url.matchesReaderURL(readerContent.pageURL) else {
                Task { @MainActor in
                    if contentSelection.wrappedValue == selection {
                        contentSelection.wrappedValue = nil
                    }
                }
                return
            }
            contentSelectionNavigationHint?(content.url, selection)
            Task { @MainActor in
                do {
                    try await navigator.load(
                        content: content,
                        readerModeViewModel: readerModeViewModel
                    )
                } catch {
                    debugPrint("Failed to load reader content from horizontal list", error)
                }
                if contentSelection.wrappedValue == selection {
                    contentSelection.wrappedValue = nil
                }
            }
        } label: {
            GroupBox {
                VStack(spacing: 0) {
                    if let customMenuOptions {
                        content.readerContentCellView(
                            appearance: ReaderContentCellAppearance(
                                maxCellHeight: maxCellHeight,
                                alwaysShowThumbnails: true,
                                isEbookStyle: content.isPhysicalMedia,
                                includeSource: includeSource,
                                thumbnailDimension: maxCellHeight
                            ),
                            customMenuOptions: customMenuOptions
                        )
                        .readerContentCellStyle(.card)
                    } else {
                        content.readerContentCellView(
                            appearance: ReaderContentCellAppearance(
                                maxCellHeight: maxCellHeight,
                                alwaysShowThumbnails: true,
                                isEbookStyle: content.isPhysicalMedia,
                                includeSource: includeSource,
                                thumbnailDimension: maxCellHeight
                            )
                        )
                        .readerContentCellStyle(.card)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .applyStackListGroupBoxStyle(.automatic, defaultIsGrouped: stackListStyle == .grouped)
            .stackListGroupBoxContentInsets(ReaderContentHorizontalListLayout.groupBoxContentInsets)
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .environmentObject(cloudDriveSyncStatusModel)
        .task { @MainActor in
            if let item = content as? ContentFile {
                await cloudDriveSyncStatusModel.refreshAsync(item: item)
            }
        }
        .onPreferenceChange(ReaderContentBookCoverRenderedWidthPreferenceKey.self) { width in
            guard content.isPhysicalMedia, width > 0 else { return }
            guard let measuredPhysicalCoverWidth else {
                self.measuredPhysicalCoverWidth = width
                return
            }
            if abs(measuredPhysicalCoverWidth - width) >= 0.5 {
                self.measuredPhysicalCoverWidth = width
            }
        }
        .onChange(of: content.compoundKey) { _ in
            measuredPhysicalCoverWidth = nil
        }
    }
}

fileprivate struct ReaderContentInnerHorizontalList<C: ReaderContentProtocol>: View {
    var filteredContents: [C]
    let includeSource: Bool
    let customMenuOptions: ((C) -> AnyView)?
    let contentSelection: Binding<String?>
    let onContentSelected: ((C) -> Void)?
    let resetScrollOnAppear: Bool

    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var scrollPositionID: String?
    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 130

    var body: some View {
        Group {
            if #available(iOS 17, macOS 14, *) {
                ScrollView(.horizontal) {
                    contentStack
                }
                .scrollIndicators(.hidden, axes: .horizontal)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrollPositionID, anchor: .leading)
                .onAppear { applyScrollPosition() }
                .onChange(of: filteredContents.map(\.compoundKey)) { _ in
                    applyScrollPosition()
                }
                .scrollClipDisabled()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        contentStack
                    }
                    .modifier {
                        if #available(iOS 16, macOS 13, *) {
                            $0.scrollIndicators(.hidden, axes: .horizontal)
                        } else {
                            $0
                        }
                    }
                    .onAppear {
                        scheduleScrollToStart(proxy: proxy)
                    }
                    .onChange(of: filteredContents.map(\.compoundKey)) { _ in
                        scheduleScrollToStart(proxy: proxy)
                    }
                }
            }
        }
    }

    init(
        filteredContents: [C],
        includeSource: Bool,
        customMenuOptions: ((C) -> AnyView)? = nil,
        contentSelection: Binding<String?>,
        onContentSelected: ((C) -> Void)? = nil,
        resetScrollOnAppear: Bool = false
    ) {
        self.filteredContents = filteredContents
        self.includeSource = includeSource
        self.customMenuOptions = customMenuOptions
        self.contentSelection = contentSelection
        self.onContentSelected = onContentSelected
        self.resetScrollOnAppear = resetScrollOnAppear
    }

    @MainActor
    private func applyScrollPosition() {
        guard resetScrollOnAppear, let firstID = filteredContents.first?.compoundKey else { return }
        Task { @MainActor in
            scrollPositionID = firstID
        }
    }

    private func scheduleScrollToStart(proxy: ScrollViewProxy) {
        guard resetScrollOnAppear, let firstID = filteredContents.first?.compoundKey else { return }
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            proxy.scrollTo(firstID, anchor: .leading)
        }
    }

    @ViewBuilder
    private var contentStack: some View {
        HStack(spacing: 15) {
            ForEach(filteredContents, id: \.compoundKey) { content in
                ReaderContentInnerHorizontalListItem(
                    content: content,
                    includeSource: includeSource,
                    maxCellHeight: maxCellHeight,
                    customMenuOptions: customMenuOptions,
                    contentSelection: contentSelection,
                    onContentSelected: onContentSelected
                )
                .id(content.compoundKey)
            }
        }
        .modifier {
            if #available(iOS 17, macOS 14, *) {
                $0.scrollTargetLayout()
            } else {
                $0
            }
        }
        .frame(minHeight: maxCellHeight)
    }
}

public struct ReaderContentHorizontalList<C: ReaderContentProtocol, EmptyState: View>: View {
    let contents: [C]
    let includeSource: Bool
    var contentSelection: Binding<String?>
    let emptyStateView: () -> EmptyState
    let customMenuOptions: ((C) -> AnyView)?
    let onContentSelected: ((C) -> Void)?
    let resetScrollOnAppear: Bool
    let postSortTransform: (@ReaderContentListActor ([C]) -> [C])?

    @StateObject private var viewModel = ReaderContentListViewModel<C>()
    @ScaledMetric(relativeTo: .headline) private var maxCellHeight: CGFloat = 130
    var contentFilter: (@ReaderContentListActor (Int, C) async throws -> Bool) = { @ReaderContentListActor _, _ in true }
    var sortOrder = ReaderContentSortOrder.publicationDate

    private var estimatedRowHeight: CGFloat {
        maxCellHeight
            + ReaderContentHorizontalListLayout.groupBoxContentInsets.top
            + ReaderContentHorizontalListLayout.groupBoxContentInsets.bottom
    }

    public var body: some View {
        ZStack {
            if viewModel.showLoadingIndicator || !viewModel.filteredContents.isEmpty {
                ReaderContentInnerHorizontalList(
                    filteredContents: viewModel.filteredContents,
                    includeSource: includeSource,
                    customMenuOptions: customMenuOptions,
                    contentSelection: contentSelection,
                    onContentSelected: onContentSelected,
                    resetScrollOnAppear: resetScrollOnAppear
                )
            }

            if !viewModel.showLoadingIndicator, viewModel.filteredContents.isEmpty {
                emptyStateView()
                    .frame(maxWidth: .infinity, minHeight: estimatedRowHeight, alignment: .topLeading)
            }

            if viewModel.showLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
                    .delayedAppearance()
            }
        }
        .frame(height: estimatedRowHeight, alignment: .top)
        .task { @MainActor in
            try? await viewModel.load(
                contents: contents,
                contentFilter: contentFilter,
                sortOrder: sortOrder,
                postSortTransform: postSortTransform
            )
        }
        .onChange(of: contents, debounceTime: 0.1) { contents in
            Task { @MainActor in
                try? await viewModel.load(
                    contents: contents,
                    contentFilter: contentFilter,
                    sortOrder: sortOrder,
                    postSortTransform: postSortTransform
                )
            }
        }
    }

    public init(
        contents: [C],
        contentFilter: ((Int, C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder? = nil,
        includeSource: Bool,
        contentSelection: Binding<String?>,
        customMenuOptions: ((C) -> AnyView)? = nil,
        onContentSelected: ((C) -> Void)? = nil,
        postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil,
        resetScrollOnAppear: Bool = false,
        @ViewBuilder emptyStateView: @escaping () -> EmptyState
    ) {
        self.contents = contents
        if let contentFilter {
            self.contentFilter = contentFilter
        }
        if let sortOrder {
            self.sortOrder = sortOrder
        }
        self.includeSource = includeSource
        self.contentSelection = contentSelection
        self.customMenuOptions = customMenuOptions
        self.onContentSelected = onContentSelected
        self.postSortTransform = postSortTransform
        self.resetScrollOnAppear = resetScrollOnAppear
        self.emptyStateView = emptyStateView
    }
}

public extension ReaderContentHorizontalList where EmptyState == EmptyView {
    init(
        contents: [C],
        includeSource: Bool = false,
        contentFilter: ((C) async throws -> Bool)? = nil,
        sortOrder: ReaderContentSortOrder? = nil
    ) {
        self.init(
            contents: contents,
            contentFilter: contentFilter.map { contentFilter in
                { _, content in
                    try await contentFilter(content)
                }
            },
            sortOrder: sortOrder,
            includeSource: includeSource,
            contentSelection: .constant(nil),
            customMenuOptions: nil,
            onContentSelected: nil,
            postSortTransform: nil,
            resetScrollOnAppear: false
        ) {
            EmptyView()
        }
    }
}
