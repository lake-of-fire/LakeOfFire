import SwiftUI
import RealmSwift
import RealmSwiftGaps

@globalActor
fileprivate actor ReaderContentCellActor {
    static var shared = ReaderContentCellActor()
}

class ReaderContentCellViewModel<C: ReaderContentProtocol & ObjectKeyIdentifiable>: ObservableObject {
    @Published var readingProgress: Float? = nil
    @Published var isFullArticleFinished: Bool? = nil
    @Published var forceShowBookmark = false
    @Published var title = ""
    @Published var humanReadablePublicationDate: String?
    @Published var imageURL: URL?

    init() { }
    
    @MainActor
    func load(item: C) async throws {
//        guard let readingProgressLoader = ReaderContentReadingProgressLoader.readingProgressLoader else { return }
        guard let config = item.realm?.configuration else { return }
        let pk = item.compoundKey
        let imageURL = try await item.imageURLToDisplay()
        try await { @ReaderContentCellActor in
            let realm = try await Realm(configuration: config, actor: ReaderContentCellActor.shared)
            if let item = realm.object(ofType: C.self, forPrimaryKey: pk) {
                try Task.checkCancellation()
                let title = item.titleForDisplay
                let humanReadablePublicationDate = item.displayPublicationDate ? item.humanReadablePublicationDate : nil
                let progressResult = try await ReaderContentReadingProgressLoader.readingProgressLoader?(item.url)
                
                try await { @MainActor [weak self] in
                    try Task.checkCancellation()
                    humanReadablePublicationDate
                    self?.title = title
                    self?.imageURL = imageURL
                    self?.humanReadablePublicationDate = humanReadablePublicationDate
                    if let (progress, finished) = progressResult {
                        self?.readingProgress = progress
                        self?.isFullArticleFinished = finished
                    }
                }()
            }
        }()
    }
}

extension ReaderContentProtocol {
    @ViewBuilder func readerContentCellView(
        maxCellHeight: CGFloat,
        alwaysShowThumbnails: Bool = true,
        isEbookStyle: Bool = false
    ) -> some View {
        ReaderContentCell(
            item: self,
            maxCellHeight: maxCellHeight,
            alwaysShowThumbnails: alwaysShowThumbnails,
            isEbookStyle: isEbookStyle
        )
    }
}

struct CloudDriveSyncStatusView: View { //, Equatable {
    @ObservedRealmObject var item: ContentFile
    
    @EnvironmentObject var cloudDriveSyncStatusModel: CloudDriveSyncStatusModel
    
    private var title: String? {
        switch cloudDriveSyncStatusModel.status {
        case .fileMissing:
            return "File Missing"
        case .notInUbiquityContainer:
            return "Local File"
        case .downloading:
            return "Downloading from iCloud"
        case .uploading:
            return "Uploading to iCloud"
        case .synced:
            return "Synced with iCloud"
        case .notSynced:
            return "Not Synced with iCloud"
        case .loadingStatus:
            return nil
        }
    }
    
    private var systemImage: String? {
        switch cloudDriveSyncStatusModel.status {
        case .fileMissing:
            return "exclamationmark.icloud"
        case .notInUbiquityContainer:
            return "icloud.slash"
        case .downloading:
            return "icloud.and.arrow.down"
        case .uploading:
            return "icloud.and.arrow.up"
        case .synced:
            return "checkmark.icloud.fill"
        case .notSynced:
            return "xmark.icloud"
        case .loadingStatus:
            return nil
        }
    }
    
    var body: some View {
        if let title = title, let systemImage = systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text("")
                .hidden()
        }
    }
}

struct ReaderContentCell<C: ReaderContentProtocol & ObjectKeyIdentifiable>: View { //, Equatable {
    @ObservedRealmObject var item: C
    let maxCellHeight: CGFloat
    var alwaysShowThumbnails = true
    var isEbookStyle = false
    
    static var buttonSize: CGFloat {
        return 26
    }
    
    var scaledImageWidth: CGFloat {
        return maxCellHeight
    }
    
    @EnvironmentObject private var readerContentListModalsModel: ReaderContentListModalsModel
    
    @StateObject private var viewModel = ReaderContentCellViewModel<C>()

    private var buttonSize: CGFloat {
        return ReaderContentCell<C>.buttonSize
    }
    
    private var isProgressVisible: Bool {
        if let readingProgressFloat = viewModel.readingProgress, readingProgressFloat > 0 {
            return true
        }
        return false
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let imageUrl = viewModel.imageURL {
                if isEbookStyle {
                    BookThumbnail(imageURL: imageUrl, scaledImageWidth: scaledImageWidth, cellHeight: maxCellHeight)
//                        .frame(maxWidth: scaledImageWidth, maxHeight: cellHeight)
                } else {
                    ReaderImage(imageUrl, maxWidth: scaledImageWidth, minHeight: maxCellHeight, maxHeight: maxCellHeight)
                        .clipShape(RoundedRectangle(cornerRadius: scaledImageWidth / 16))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(viewModel.title)
                    .font(.headline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor((viewModel.isFullArticleFinished ?? false) ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let publicationDate = viewModel.humanReadablePublicationDate {
                                Text("\(publicationDate)")
                                    .lineLimit(9001)
                                    .font(.footnote)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if let item = item as? ContentFile {
                                CloudDriveSyncStatusView(item: item)
                                    .labelStyle(.iconOnly)
                                    .font(.callout)
                            }
                        }
                        .foregroundStyle(.secondary)

                        if let readingProgressFloat = viewModel.readingProgress, isProgressVisible {
                                ProgressView(value: min(1, readingProgressFloat))
                                    .tint((viewModel.isFullArticleFinished ?? false) ? Color("Green") : .secondary)
                            }
                    }
#if os(macOS)
                    .padding(.bottom, isProgressVisible ? buttonSize / 2 - 10 : buttonSize / 2 - 5)
#elseif os(iOS)
                    .padding(.bottom, isProgressVisible ? buttonSize / 2 - 3 : buttonSize / 2 - 7)
#endif

                    Spacer(minLength: 0)
                            
                    HStack(alignment: .center, spacing: 0) {
                        BookmarkButton(width: buttonSize, height: buttonSize, iconOnly: true, readerContent: item, hiddenIfUnbookmarked: true)
                            .buttonStyle(.borderless)
                            .padding(.leading, 2)
                        
                        if let item = item as? (any DeletableReaderContent) {
                            Menu {
                                if let item = item as? ContentFile {
                                    CloudDriveSyncStatusView(item: item)
                                        .labelStyle(.titleAndIcon)
                                    Divider()
                                }
                                
                                Button(role: .destructive) {
                                    readerContentListModalsModel.confirmDeletionOf = item
                                    readerContentListModalsModel.confirmDelete = true
                                } label: {
                                    Label(item.deleteActionTitle, systemImage: "trash")
                                }
                            } label: {
                                Label("More Options", systemImage: "ellipsis")
                                //                                .foregroundStyle(.secondary)
                                //                                .foregroundStyle(.blue)
                                    .background(.white.opacity(0.0000000001))
                                //                                .overlay(.white.opacity(0.0000000001))
                                    .frame(width: buttonSize, height: buttonSize)
                                //                                .background(.green)
                                //                            #if os(macOS)
                                //                                .padding(.horizontal, 4)
                                //                                .padding(.vertical, 10)
                                //                            #else
                                //#endif
                                    .labelStyle(.iconOnly)
                            }
                            .foregroundStyle(.secondary)
                            //                        .frame(width: buttonSize, height: buttonSize)
                            .menuIndicator(.hidden)
                            .buttonStyle(.borderless)
                            //                        .buttonStyle(.borderless)
                            //                        .buttonStyle(.plain)
                            //#if os(macOS)
                            //                        .offset(y: -(buttonSize / 2.5)) // IDK why
                            //                                                        //                        .offset(y: 3)
                            //#endif
                        }
                    }
                }
                .padding(.trailing, 5)
            }
            .frame(maxHeight: maxCellHeight)
        }
        .frame(minWidth: maxCellHeight, idealHeight: alwaysShowThumbnails ? maxCellHeight : (viewModel.imageURL == nil ? nil : maxCellHeight))
        .onHover { hovered in
            viewModel.forceShowBookmark = hovered
        }
        .onAppear {
            Task { @MainActor in
                try? await viewModel.load(item: item)
            }
        }
        .onChange(of: item.imageUrl) { newImageURL in
            guard newImageURL != viewModel.imageURL else { return }
            Task { @MainActor in
                viewModel.imageURL = try await item.imageURLToDisplay()
            }
        }
    }
}
