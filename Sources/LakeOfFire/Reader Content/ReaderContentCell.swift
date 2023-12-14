import Foundation
import SwiftUI
import RealmSwift
import LakeImage

class ReaderContentCellViewModel<C: ReaderContentModel & ObjectKeyIdentifiable>: ObservableObject {
    @Published var readingProgress: Float? = nil
    @Published var isFullArticleFinished: Bool? = nil
    @Published var bookmarkExists = false
    
    init() { }
    
    @MainActor
    func load(item: C) {
        guard let readingProgressLoader = ReaderContentReadingProgressLoader.readingProgressLoader else { return }
        guard let config = item.realm?.configuration else { return }
        let pk = item.compoundKey
        //        let url = item.url
        //        let item = item.freeze()
        Task.detached {
            let realm = try! Realm(configuration: config)
            if let item = realm.object(ofType: C.self, forPrimaryKey: pk) {
                if let (progress, finished) = readingProgressLoader(item) {
                    Task { @MainActor in
                        self.readingProgress = progress
                        self.isFullArticleFinished = finished
                    }
                }
                let bookmarkExists = item.bookmarkExists(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                Task { @MainActor in
                    self.bookmarkExists = bookmarkExists
                }
            }
        }
    }
}

struct ReaderContentCell<C: ReaderContentModel & ObjectKeyIdentifiable>: View { //, Equatable {
    @ObservedRealmObject var item: C
    @ScaledMetric(relativeTo: .headline) var scaledImageWidth: CGFloat = 140
    @ScaledMetric(relativeTo: .headline) var cellHeight: CGFloat = 90
    
    @StateObject var viewModel = ReaderContentCellViewModel<C>()
    @State var forceShowBookmark = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let imageUrl = item.imageURLToDisplay {
                VStack(spacing: 0) {
                    LakeImage(imageUrl, maxWidth: scaledImageWidth, minHeight: cellHeight, maxHeight: cellHeight)
//                        .frame(maxWidth: scaledImageWidth)
                        .frame(idealHeight: cellHeight)
                        .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
                        .clipShape(RoundedRectangle(cornerRadius: scaledImageWidth / 12))
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
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
                        .padding(.trailing, 5)
#if os(macOS)
                    Spacer(minLength: 0)
                    Button {
                        Task { @MainActor in
                            forceShowBookmark = try await item.toggleBookmark(realmConfiguration: ReaderContentLoader.bookmarkRealmConfiguration)
                        }
                    } label: {
                        Image(systemName: viewModel.bookmarkExists ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.borderless)
                    .opacity(viewModel.bookmarkExists || forceShowBookmark ? 1 : 0)
#endif
                }
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        if item.displayPublicationDate, let publicationDate = item.humanReadablePublicationDate {
                            VStack {
                                Text("\(publicationDate)")
                            }
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        }
                        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
                            ProgressView(value: min(1, readingProgressFloat))
                                .tint((viewModel.isFullArticleFinished ?? false) ? Color("Green") : .secondary)
                        }
                    }
#if os(iOS)
                    if viewModel.bookmarkExists {
                        Spacer(minLength: 0)
                        Image(systemName: "bookmark.fill")
                            .padding(.leading, 5)
                    }
#endif
                }
            }
//                    .frame(maxHeight: .infinity)
            
//#if os(macOS)
            Spacer(minLength: 0)
//#endif
        }
        .fixedSize(horizontal: false, vertical: true)
#if os(macOS)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .padding(.horizontal, 8)
#else
        .padding(.vertical, 4)
#endif
        .onHover { hovered in
            forceShowBookmark = hovered
        }
        .task {
            viewModel.load(item: item)
        }
    }
    
//    static func == (lhs: ReaderContentCell<C>, rhs: ReaderContentCell<C>) -> Bool {
//        return lhs.item.compoundKey == rhs.item.compoundKey && lhs.item.bookmarkExists(realmConfiguration: ManabiReaderRealmConfigurer.configuration) == rhs.item.bookmarkExists(realmConfiguration: ManabiReaderRealmConfigurer.configuration) && lhs.articleReadingProgress == rhs.articleReadingProgress
//    }
}
