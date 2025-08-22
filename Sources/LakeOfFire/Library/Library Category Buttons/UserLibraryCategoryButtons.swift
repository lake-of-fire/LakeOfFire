import SwiftUI
import Combine
import RealmSwiftGaps
import RealmSwift

public struct UserLibraryCategoryButtons: View {
    @Binding var feedSelection: String?
    @Binding var categorySelection: String?
    var isCompact = false
    
    public var body: some View {
        ContentCategoryButtons(
            feedSelection: $feedSelection,
            categorySelection: $categorySelection,
            isCompact: isCompact,
            categoryFilter: { feedCategory in
                // Note: could parameterize this later for multiple sources of remote category lists
                return feedCategory.opmlURL == nil
            },
            additionalCategories: {
#if DEBUG
                MangaCategoryButton(
                    categorySelection: $categorySelection,
                    isCompact: isCompact
                )
#endif
                
                BooksCategoryButton(
                    categorySelection: $categorySelection,
                    isCompact: isCompact
                )
            }
        )
    }
    
    public init(
        feedSelection: Binding<String?>,
        categorySelection: Binding<String?>,
        isCompact: Bool = false
    ) {
        _feedSelection = feedSelection
        _categorySelection = categorySelection
        self.isCompact = isCompact
    }
}

public struct MangaCategoryButton: View {
    @Binding var categorySelection: String?
    var isCompact = false
    
    public var body: some View {
        Button(action: {
            withAnimation {
                categorySelection = "manga"
            }
        }) {
            FeedCategoryButtonLabel(
                title: "Manga",
                backgroundImageURL: URL(string: "https://reader.manabi.io/static/reader/category_images/manga.jpg")!,
                isCompact: isCompact
            )
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(
        categorySelection: Binding<String?>,
        isCompact: Bool
    ) {
        _categorySelection = categorySelection
        self.isCompact = isCompact
    }
}

public struct BooksCategoryButton: View {
    @Binding var categorySelection: String?
    var isCompact = false
    
    public var body: some View {
        Button(action: {
            withAnimation {
                categorySelection = "books"
            }
        }) {
            FeedCategoryButtonLabel(title: "Books", backgroundImageURL: URL(string: "https://reader.manabi.io/static/reader/category_images/books.jpg")!, isCompact: isCompact)
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(
        categorySelection: Binding<String?>,
        isCompact: Bool
    ) {
        _categorySelection = categorySelection
        self.isCompact = isCompact
    }
}
