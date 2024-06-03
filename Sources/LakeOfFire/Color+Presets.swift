import SwiftUI
import SwiftUIX

public extension Color {
    static var groupBoxBackground: Color {
#if os(iOS)
        return .systemGroupedBackground
#else
        return Color.secondary.opacity(0.18)
#endif
    }
}
