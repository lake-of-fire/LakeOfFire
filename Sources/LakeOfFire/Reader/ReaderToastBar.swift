import SwiftUI
import LakeKit

public enum ReaderToastShadowStyle {
    case enabled
    case disabled
}

private struct ReaderToastShadowStyleKey: EnvironmentKey {
    static let defaultValue: ReaderToastShadowStyle = .enabled
}

public extension EnvironmentValues {
    var readerToastShadowStyle: ReaderToastShadowStyle {
        get { self[ReaderToastShadowStyleKey.self] }
        set { self[ReaderToastShadowStyleKey.self] = newValue }
    }
}

private enum ReaderToastBarMetrics {
#if os(macOS)
    static let horizontalContentPadding: CGFloat = 10
#else
    static let horizontalContentPadding: CGFloat = 8
#endif
}

/// Capsule-shaped toast container reused by multiple bars.
public struct ReaderToastBar<Content: View>: View {
    @Binding private var isPresented: Bool
    private let onDismiss: (() -> Void)?
    private let content: Content
    private let trailingAccessory: AnyView?
    
    @Environment(\.readerToastShadowStyle) private var shadowStyle

    public init(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            isPresented: isPresented,
            onDismiss: onDismiss,
            trailingAccessory: { Optional<EmptyView>.none },
            content: content
        )
    }
    
    public init<Accessory: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder trailingAccessory: () -> Accessory? = { nil },
        @ViewBuilder content: () -> Content
    ) {
        self._isPresented = isPresented
        self.onDismiss = onDismiss
        self.content = content()
        if let accessory = trailingAccessory() {
            self.trailingAccessory = AnyView(accessory)
        } else {
            self.trailingAccessory = nil
        }
    }
    
    public var body: some View {
        if isPresented {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    content
                        .padding(.leading, ReaderToastBarMetrics.horizontalContentPadding)
                        .padding(.trailing, ReaderToastBarMetrics.horizontalContentPadding)
                    
                    if let trailingAccessory {
                        Spacer(minLength: 0)
                        trailingAccessory
                    } else if onDismiss != nil {
                        Spacer(minLength: 0)
                        DismissButton(.xMark, fill: true) {
                            withAnimation {
                                isPresented = false
                                onDismiss?()
                            }
                        }
                        .modifier { view in
                            if #available(iOS 15, macOS 12, *) {
                                view.foregroundStyle(.secondary)
                            } else {
                                view.foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(2)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(radius: shadowStyle == .enabled ? 2 : 0)
                Spacer(minLength: 0)
            }
#if os(iOS)
            .padding(.horizontal, 4)
#else
            .padding(.horizontal, 4)
#endif
            .padding(.vertical, 4)
        }
    }
}
