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
    @ViewBuilder func readerContentCellView(alwaysShowThumbnails: Bool = true) -> some View {
        ReaderContentCell(item: self, alwaysShowThumbnails: alwaysShowThumbnails)
    }
}

struct ReaderContentCell<C: ReaderContentModel & ObjectKeyIdentifiable>: View { //, Equatable {
    @ObservedRealmObject var item: C
    var alwaysShowThumbnails = true
    var isEbookStyle = false
    
    @ScaledMetric(relativeTo: .headline) private var scaledImageWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .headline) private var cellHeight: CGFloat = 100
    
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let imageUrl = item.imageURLToDisplay {
//                VStack(spacing: 0) {
                    if isEbookStyle {
                        BookThumbnail(imageURL: imageUrl)
                            .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
                    } else {
//                        LakeImage(imageUrl, contentMode: .fit, maxWidth: scaledImageWidth, maxHeight: cellHeight)
                        LakeImage(imageUrl, maxWidth: scaledImageWidth, minHeight: cellHeight, maxHeight: cellHeight)
//                            .frame(idealHeight: cellHeight)
//                            .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
                            .clipShape(RoundedRectangle(cornerRadius: scaledImageWidth / 16))
                    }
//                }
//                .frame(maxHeight: .infinity)
//                .background(.purple.opacity(0.3))
//                .padding(.trailing, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    Text(item.titleForDisplay)
                        .font(.headline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor((viewModel.isFullArticleFinished ?? false) ? Color.secondary : Color.primary)
//                        .padding(.trailing, 5)
#if os(macOS)
                    Spacer(minLength: 0)
                    BookmarkButton(readerContent: item, hiddenIfUnbookmarked: !viewModel.forceShowBookmark)
                        .buttonStyle(.borderless)
#endif
                }
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
                                .padding(.bottom, 2)
                        }
                    }
                    Spacer(minLength: 0)
#if os(iOS)
                    BookmarkButton(iconOnly: true, readerContent: item, hiddenIfUnbookmarked: true)
                        .buttonStyle(.borderless)
                        .padding(.leading, 2)
//                        .padding(.leading, 5)
                    //                    if viewModel.bookmarkExists {
                    //                        Spacer(minLength: 0)
                    //                        Image(systemName: "bookmark.fill")
                    //                            .padding(.leading, 5)
                    //                    }
#endif
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
                                .padding(.horizontal, 4)
                                .padding(.vertical, 10)
                                .labelStyle(.iconOnly)
                        }
                        .foregroundStyle(.secondary)
                        .menuIndicator(.hidden)
                        .offset(y: 3)
                        //                    .menuStyle(.borderlessButton)
                    }
                }
            }
            .frame(maxHeight: cellHeight)
        }
        .frame(minWidth: cellHeight, idealHeight: alwaysShowThumbnails ? cellHeight : (item.imageURLToDisplay == nil ? nil : cellHeight))
//                    .frame(maxHeight: .infinity)
            
//#if os(macOS)
//            Spacer(minLength: 0)
//#endif
//        }
//        .fixedSize(horizontal: false, vertical: true)
//        .padding(4)
        .onHover { hovered in
            viewModel.forceShowBookmark = hovered
        }
        .task {
            viewModel.load(item: item)
        }
    }
    
//    static func == (lhs: ReaderContentCell<C>, rhs: ReaderContentCell<C>) -> Bool {
//        return lhs.item.compoundKey == rhs.item.compoundKey && lhs.item.bookmarkExists(realmConfiguration: ManabiReaderRealmConfigurer.configuration) == rhs.item.bookmarkExists(realmConfiguration: ManabiReaderRealmConfigurer.configuration) && lhs.articleReadingProgress == rhs.articleReadingProgress
//    }
}
