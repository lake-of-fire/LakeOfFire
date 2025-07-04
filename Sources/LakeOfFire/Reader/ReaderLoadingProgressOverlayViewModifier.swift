import SwiftUI

// TODO: Instead of layering this across eg Reader and ManabiReader, have it once and use environment to set its activation (or similar)
public struct ReaderLoadingProgressOverlayViewModifier: ViewModifier {
    // For some reason it doesn't always redraw if simply let isLoading: Bool
//    @Binding var isLoading: Bool
    let isLoading: Bool

//    public init(isLoading: Binding<Bool>) {
//        _isLoading = isLoading
//    }
    public init(isLoading: Bool) {
        self.isLoading = isLoading
    }

    @Environment(\.colorScheme) private var colorScheme
//    @State private var ee = UUID().uuidString.prefix(4)
    
    public func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    Rectangle()
                        .fill(colorScheme == .dark ? .black.opacity(0.7) : .white.opacity(0.7))
                    Rectangle()
                        .fill(.ultraThickMaterial)
                    ProgressView()
                        .tint(.secondary)
                        .delayedAppearance()
                }
                .ignoresSafeArea(.all)
                .opacity(isLoading ? 1 : 0)
                .allowsHitTesting(isLoading)
            }
    }
}
