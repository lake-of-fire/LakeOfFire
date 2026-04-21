import SwiftUI
import LakeImage
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public struct FeedCategoryImage: View {
    private let imageURL: URL
    
    public var body: some View {
        GeometryReader { proxy in
            LakeImage(imageURL)
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    Color.black.opacity(0.18)
                }
        }
    }
    
    public init(imageURL: URL) {
        self.imageURL = imageURL
    }
}
