import SwiftUI
import LakeImage

public struct FeedCategoryImage: View {
    private let imageURL: URL

#if os(iOS)
    private let backingColor = Color(UIColor.secondarySystemBackground)
#elseif os(macOS)
    private let backingColor = Color(NSColor.controlBackgroundColor)
#else
    private let backingColor = Color(.secondarySystemBackground)
#endif
    
    public var body: some View {
        GeometryReader { proxy in
            backingColor
                .overlay {
                    LakeImage(imageURL)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay {
                            Color.black.opacity(0.18)
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                }
                .compositingGroup()
            }
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
        }
    }
    
    public init(imageURL: URL) {
        self.imageURL = imageURL
    }
}
