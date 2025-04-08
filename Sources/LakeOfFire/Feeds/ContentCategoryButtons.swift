import SwiftUI
import Combine
import RealmSwiftGaps
import RealmSwift

@MainActor
fileprivate class ContentCategoryButtonsViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration?

    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        Task { @RealmBackgroundActor [weak self] in
             let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) 
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
                        let libraryConfigurationID = libraryConfiguration.id
                        
                        try await { @MainActor [weak self] in
                            guard let self else { return }
                            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                            self.libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID)
                        }()
                    }
                })
                .store(in: &cancellables)
 
            realm.objects(FeedCategory.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    self?.objectWillChange.send() // Refresh view for LibraryConfiguration's categories
                })
                .store(in: &cancellables)
        }
    }
}

public struct ContentCategoryButtons: View {
    @Binding var feedSelection: String?
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
    
    @StateObject private var viewModel = ContentCategoryButtonsViewModel()
    
    @ScaledMetric(relativeTo: .headline) private var minWidth: CGFloat = 190
    
//    private var gridColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    private var gridColumns: [GridItem] {
        get {
            [GridItem(.adaptive(minimum: minWidth))] //, maximum: maxWidth))]
        }
    }
    
    public var body: some View {
        if let categories = viewModel.libraryConfiguration?.getActiveCategories() {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
#if DEBUG
                MangaCategoryButton(
                    categorySelection: $categorySelection,
                    font: font,
                    isCompact: isCompact
                )
#endif
                
                BooksCategoryButton(
                    categorySelection: $categorySelection,
                    font: font,
                    isCompact: isCompact
                )
                
                ForEach(categories) { category in
                    FeedCategoryButton(
                        category: category,
                        feedSelection: $feedSelection,
                        categorySelection: $categorySelection,
                        font: font,
                        isCompact: isCompact
                    )
                }
            }
        }
    }
    
    public init(feedSelection: Binding<String?>, categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool = false) {
        _feedSelection = feedSelection
        _categorySelection = categorySelection
        self.font = font
        self.isCompact = isCompact
    }
}

public struct MangaCategoryButton: View {
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
    
    public var body: some View {
        Button(action: {
            withAnimation {
                categorySelection = "manga"
            }
        }) {
            FeedCategoryButtonLabel(title: "Manga", backgroundImageURL: URL(string: "https://reader.manabi.io/static/reader/category_images/manga.jpg")!, font: font, isCompact: isCompact)
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool) {
        _categorySelection = categorySelection
        self.font = font
        self.isCompact = isCompact
    }
}

public struct BooksCategoryButton: View {
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
    
    public var body: some View {
        Button(action: {
            withAnimation {
                categorySelection = "books"
            }
        }) {
            FeedCategoryButtonLabel(title: "Books", backgroundImageURL: URL(string: "https://reader.manabi.io/static/reader/category_images/books.jpg")!, font: font, isCompact: isCompact)
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool) {
        _categorySelection = categorySelection
        self.font = font
        self.isCompact = isCompact
    }
}

public struct FeedCategoryButton: View {
    let category: FeedCategory
    @Binding var feedSelection: String?
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
    
    public var body: some View {
        Button(action: {
            feedSelection = nil
            categorySelection = category.id.uuidString
        }) {
            FeedCategoryButtonLabel(title: category.title, backgroundImageURL: category.backgroundImageUrl, font: font, isCompact: isCompact)
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(category: FeedCategory, feedSelection: Binding<String?>, categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool) {
        self.category = category
        _feedSelection = feedSelection
        _categorySelection = categorySelection
        self.font = font
        self.isCompact = isCompact
    }
}

struct ReaderCategoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
//            .clipped()
//#if os(iOS)
//            .clipShape(Capsule())
//#else
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary.opacity(0.2))
                    .shadow(radius: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
//#endif
            .buttonStyle(.borderless)
        //            .buttonStyle(.plain)
//            .brightness(-0.1)
            .scaleEffect(configuration.isPressed ? 0.994 : 1.0)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.05), value: configuration.isPressed)
//            .overlay(
//                RoundedRectangle(cornerRadius: 6, style: .continuous)
//                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
//            )
    }
}

public struct FeedCategoryButtonLabel: View {
    let title: String
    let backgroundImageURL: URL
    var font = Font.title3
    var isCompact = false
    var showEditingDisabled: Bool = false
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 40
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 30
#endif
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    private var titleToDisplay: String {
        return title.isEmpty ? "Untitled" : title
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                if showEditingDisabled {
                    Image(systemName: "lock.fill")
                }
                Text(titleToDisplay)
                    .bold()
            }
            .font(font)
//            .foregroundColor(.white)
            .foregroundStyle(.white)
            .opacity(title.isEmpty ? 0.85 : 1)
            //                .shadow(color: .black.opacity(0.95), radius: 4)
            .shadow(color: .black, radius: 1)
            .shadow(color: .black, radius: 3)
            .shadow(color: .black.opacity(0.5), radius: 15)
            Spacer(minLength: 0)
        }
        .frame(minHeight: isCompact ? nil : scaledCategoryHeight, alignment: .leading)
        .frame(maxWidth: .infinity)
#if os(iOS)
        .frame(idealHeight: isCompact || horizontalSizeClass == .compact ? scaledCategoryHeight : scaledCategoryHeight * 2.4)
#else
        .frame(idealHeight: isCompact ? nil : scaledCategoryHeight * 2.4)
#endif
        //            .padding(.horizontal, scaledCategoryHeight * 0.36)
        .overlay(Color.white.opacity(0.0000001)) // Weird macOS hack...
        .background {
            FeedCategoryImage(imageURL: backgroundImageURL)
            //                            .frame(maxHeight: isInSidebar ? scaledCategoryHeight : 110)
                .allowsHitTesting(false)
        }
        .multilineTextAlignment(.leading)
    }
    
    public init(
        title: String,
        backgroundImageURL: URL,
        font: Font = Font.title3,
        isCompact: Bool,
        scaledCategoryHeight: CGFloat? = nil,
        showEditingDisabled: Bool = false
    ) {
        self.title = title
        self.backgroundImageURL = backgroundImageURL
        self.font = font
        self.isCompact = isCompact
        self.showEditingDisabled = showEditingDisabled
    }
}
