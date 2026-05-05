import SwiftUI
import LakeKit

public extension Color {
    static var groupBoxBackground: Color {
#if os(iOS)
        return .systemGray6
#else
        return Color.secondary.opacity(0.18)
#endif
    }
}
