import SwiftUI
import RealmSwiftGaps
import RealmSwift
import LakeOfFireCore
import LakeOfFireAdblock

public struct EditorsPicksLibraryCategoryButtons: View {
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
                return feedCategory.opmlURL != nil
            },
            additionalCategories: { }
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
