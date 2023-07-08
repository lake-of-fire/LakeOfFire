import SwiftUI
import LakeImage

public struct FeedCategoryImage: View {
    private let imageURL: URL
    
    public var body: some View {
        EmptyView()
        LakeImage(imageURL)
            .scaledToFill()
            .overlay {
                Color.black.opacity(0.18)
            }
    }
    
    public init(category: FeedCategory) {
        imageURL = category.backgroundImageUrl
    }
}
