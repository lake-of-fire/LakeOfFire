import SwiftUI

/// Lays out any number of toast bars, switching between vertical and horizontal
/// based on size class (iOS) or platform (macOS = always horizontal).
public struct ReaderToastsView: View {
    private let bars: [AnyView]
    private let style: ReaderToastBarStyle
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    public init(bars: [AnyView], style: ReaderToastBarStyle = .bordered) {
        self.bars = bars
        self.style = style
    }
    
    public var body: some View {
        Group {
#if os(iOS)
            if horizontalSizeClass == .compact {
                VStack(spacing: 0) {
                    barsContent
                }
            } else {
                HStack(spacing: 0) {
                    barsContent
                }
            }
#else
            HStack(spacing: 0) {
                barsContent
            }
#endif
        }
    }
    
    @ViewBuilder
    private var barsContent: some View {
        // TODO: this kind of id: is bad... should be done like ToolbarItemGroup stuff
        ForEach(Array(bars.enumerated()), id: \.offset) { _, view in
            view
                .environment(\.readerToastBarStyle, style)
        }
    }
}
