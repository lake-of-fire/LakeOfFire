import SwiftUI
import RealmSwiftGaps
import RealmSwift

@MainActor
fileprivate class ContentCategoryButtonsViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration? {
        didSet {
            Task.detached { @RealmBackgroundActor [weak self] in
                guard let self = self else { return }
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.getOrCreate())
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
                    guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                    objectNotificationToken?.invalidate()
                    objectNotificationToken = libraryConfiguration
                        .observe(keyPaths: ["id", "categories.title", "categories.backgroundImageUrl", "categories.isArchived", "categories.isDeleted"]) { [weak self] change in
                            guard let self = self else { return }
                            switch change {
                            case .change(_, _), .deleted:
                                Task { @MainActor [weak self] in
                                    self?.objectWillChange.send()
                                }
                            case .error(let error):
                                print("An error occurred: \(error)")
                            }
                        }
                }
            }
        }
    }
    
    private var objectNotificationToken: NotificationToken?

    init() {
        Task.detached { @RealmBackgroundActor [weak self] in
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.getOrCreate())
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
                guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                self.libraryConfiguration = libraryConfiguration
            }
        }
    }
    
    deinit {
        objectNotificationToken?.invalidate()
    }
}

public struct ContentCategoryButtons: View {
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
    
    @StateObject private var viewModel = ContentCategoryButtonsViewModel()
    
    @ScaledMetric(relativeTo: .headline) private var minWidth: CGFloat = 190
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
//    private var gridColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    private var gridColumns: [GridItem] {
        get {
            [GridItem(.adaptive(minimum: minWidth))] //, maximum: maxWidth))]
        }
    }

    private var isConsideredCompact: Bool {
#if os(iOS)
        return isCompact || horizontalSizeClass == .compact
#else
        return isCompact
#endif
    }
    
    public var body: some View {
        if let categories = viewModel.libraryConfiguration?.categories {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                BooksCategoryButton(categorySelection: $categorySelection, font: font, isCompact: isCompact)
                ForEach(categories) { category in
                    FeedCategoryButton(category: category, categorySelection: $categorySelection, font: font, isCompact: isCompact)
                }
            }
        }
    }
    
    public init(categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool = false) {
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
            categorySelection = "books"
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
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
//    @SceneStorage("SidebarView.categorySelection") var categorySelection: String?
    
    public var body: some View {
        Button(action: {
            categorySelection = category.id.uuidString
        }) {
            FeedCategoryButtonLabel(title: category.title, backgroundImageURL: category.backgroundImageUrl, font: font, isCompact: isCompact)
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(category: FeedCategory, categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool) {
        self.category = category
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
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 40
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 30
#endif
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                if title.isEmpty {
                    Text("Untitled Category")
                        .fontWeight(.bold)
                        .font(font)
                        .foregroundColor(.secondary)
                } else {
                    Text(title)
                        .fontWeight(.bold)
                        .font(font)
                        .foregroundColor(.white)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 0)
            .shadow(color: .black.opacity(0.896), radius: 3, x: 0, y: 0)
            Spacer()
        }
        .frame(minHeight: isCompact ? nil : scaledCategoryHeight, alignment: .leading)
        //            .frame(maxWidth: isInSidebar || horizontalSizeClass == .compact ? .infinity : 190)
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
    
    public init(title: String, backgroundImageURL: URL, font: Font = Font.title3, isCompact: Bool, scaledCategoryHeight: CGFloat? = nil) {
        self.title = title
        self.backgroundImageURL = backgroundImageURL
        self.font = font
        self.isCompact = isCompact
    }
}
