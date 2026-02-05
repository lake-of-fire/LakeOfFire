import SwiftUI
import LakeImage
import LakeOfFireCore
import LakeOfFireAdblock

public struct ReaderContentSourceIconImage: View {
    let sourceIconURL: URL
    let iconSize: CGFloat
    
    public var body: some View {
        LakeImage(sourceIconURL)
            .cornerRadius(iconSize / 5, antialiased: true)
            .frame(width: iconSize, height: iconSize)
    }
    
    public init(sourceIconURL: URL, iconSize: CGFloat) {
        self.sourceIconURL = sourceIconURL
        self.iconSize = iconSize
    }
}
