import SwiftUI
import RealmSwift
import RealmSwiftGaps
import LakeImage

class ReaderContentCellViewModel<C: ReaderContentModel & ObjectKeyIdentifiable>: ObservableObject {
    @Published var readingProgress: Float? = nil
    @Published var isFullArticleFinished: Bool? = nil
    @Published var forceShowBookmark = false
    
    init() { }
    
    @MainActor
    func load(item: C) {
//        guard let readingProgressLoader = ReaderContentReadingProgressLoader.readingProgressLoader else { return }
        guard let config = item.realm?.configuration else { return }
        let pk = item.compoundKey
        //        let url = item.url
        //        let item = item.freeze()
        Task.detached { @RealmBackgroundActor in
            let realm = try await Realm(configuration: config, actor: RealmBackgroundActor.shared)
            if let item = realm.object(ofType: C.self, forPrimaryKey: pk) {
                if let (progress, finished) = try await ReaderContentReadingProgressLoader.readingProgressLoader?(item) {
                    Task { @MainActor in
                        self.readingProgress = progress
                        self.isFullArticleFinished = finished
                    }
                }
            }
        }
    }
}

extension ReaderContentModel {
    @ViewBuilder func readerContentCellView(alwaysShowThumbnails: Bool = true, isEbookStyle: Bool = false) -> some View {
        ReaderContentCell(item: self, alwaysShowThumbnails: alwaysShowThumbnails, isEbookStyle: isEbookStyle)
    }
    
    @ViewBuilder func readerContentCellButtonsView() -> some View {
        ReaderContentCellButtons(item: self)
    }
}

struct ReaderContentCell<C: ReaderContentModel & ObjectKeyIdentifiable>: View { //, Equatable {
    @ObservedRealmObject var item: C
    var alwaysShowThumbnails = true
    var isEbookStyle = false
    
    static var buttonSize: CGFloat {
        return 26
    }
    
    @ScaledMetric(relativeTo: .headline) private var scaledImageWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .headline) private var cellHeight: CGFloat = 100
    
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let imageUrl = item.imageURLToDisplay {
                if isEbookStyle {
                    BookThumbnail(imageURL: imageUrl)
                        .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
                } else {
                    LakeImage(imageUrl, maxWidth: scaledImageWidth, minHeight: cellHeight, maxHeight: cellHeight)
                        .clipShape(RoundedRectangle(cornerRadius: scaledImageWidth / 16))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.titleForDisplay)
                    .font(.headline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor((viewModel.isFullArticleFinished ?? false) ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        if item.displayPublicationDate, let publicationDate = item.humanReadablePublicationDate {
                            Text("\(publicationDate)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(9001)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
                            ProgressView(value: min(1, readingProgressFloat))
                                .tint((viewModel.isFullArticleFinished ?? false) ? Color("Green") : .secondary)
//                                .padding(.bottom, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    // Button placeholders:
                    Spacer()
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                    Spacer()
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                }
                .padding(.trailing, 5)
            }
            .frame(maxHeight: cellHeight)
        }
        .frame(minWidth: cellHeight, idealHeight: alwaysShowThumbnails ? cellHeight : (item.imageURLToDisplay == nil ? nil : cellHeight))
        .onHover { hovered in
            viewModel.forceShowBookmark = hovered
        }
        .task {
            viewModel.load(item: item)
        }
    }
}

struct ReaderContentCellButtons<C: ReaderContentModel & ObjectKeyIdentifiable>: View {
    @ObservedRealmObject var item: C
    
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    private var buttonSize: CGFloat {
        return ReaderContentCell<C>.buttonSize
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
//#if os(macOS)
//                    Spacer(minLength: 0)
//                    BookmarkButton(readerContent: item, hiddenIfUnbookmarked: !viewModel.forceShowBookmark)
//                        .buttonStyle(.borderless)
//#endif
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 0)
//#if os(iOS)
//                    BookmarkButton(width: buttonSize, height: buttonSize, iconOnly: true, readerContent: item, hiddenIfUnbookmarked: true)
                    BookmarkButton(width: buttonSize, height: buttonSize, iconOnly: true, readerContent: item, hiddenIfUnbookmarked: true)
                        .buttonStyle(.borderless)
                        .padding(.leading, 2)
//#endif
                    if let item = item as? (any DeletableReaderContent) {
                        Menu {
                            Button(role: .destructive) {
                                readerContentListModalsModel.confirmDeletionOf = item
                                readerContentListModalsModel.confirmDelete = true
                            } label: {
                                Label(item.deleteActionTitle, image: "trash")
                            }
                        } label: {
                            Label("More Options", systemImage: "ellipsis")
                                .foregroundStyle(.secondary)
//                            #if os(macOS)
//                                .padding(.horizontal, 4)
//                                .padding(.vertical, 10)
//                            #else
                                .frame(width: buttonSize, height: buttonSize)
//#endif
                                .labelStyle(.iconOnly)
                        }
                        .foregroundStyle(.secondary)
                        .menuIndicator(.hidden)
                        .buttonStyle(.borderless)
#if os(macOS)
                        .offset(y: -(buttonSize / 4)) // IDK why
#endif
//                        .offset(y: 3)
                    }
                }
                .padding(.trailing, 5)
            }
        }
//        .onHover { hovered in
//            viewModel.forceShowBookmark = hovered
//        }
    }
}
