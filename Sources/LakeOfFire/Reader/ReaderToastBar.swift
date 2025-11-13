import SwiftUI
import LakeKit

public enum ReaderToastBarStyle {
    case bordered
    case borderless
}

public enum ReaderToastLayoutMode {
    case standard
    case inline
}

private struct ReaderToastBarStyleKey: EnvironmentKey {
    static let defaultValue: ReaderToastBarStyle = .bordered
}

private struct ReaderToastLayoutModeKey: EnvironmentKey {
    static let defaultValue: ReaderToastLayoutMode = .standard
}

public extension EnvironmentValues {
    var readerToastBarStyle: ReaderToastBarStyle {
        get { self[ReaderToastBarStyleKey.self] }
        set { self[ReaderToastBarStyleKey.self] = newValue }
    }
    var readerToastLayoutMode: ReaderToastLayoutMode {
        get { self[ReaderToastLayoutModeKey.self] }
        set { self[ReaderToastLayoutModeKey.self] = newValue }
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
    
    @Environment(\.readerToastBarStyle) private var toastStyle
    @Environment(\.readerToastLayoutMode) private var layoutMode
    @Environment(\.controlSize) private var controlSize

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
            if layoutMode == .inline {
                inlineBody
            } else {
                standardBody
            }
        }
    }
}

private extension ReaderToastBar {
    @ViewBuilder
    var standardBody: some View {
        let horizontalPadding: CGFloat = toastStyle == .bordered ? 4 : 0
        let verticalPadding: CGFloat = toastStyle == .bordered ? 4 : 0
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                content
                    .padding(.leading, ReaderToastBarMetrics.horizontalContentPadding)
                    .padding(.trailing, ReaderToastBarMetrics.horizontalContentPadding)
                
                if let trailingAccessory, shouldShowTrailingAccessory {
                    Spacer(minLength: 0)
                    trailingAccessory
                        .padding(.trailing, ReaderToastBarMetrics.horizontalContentPadding)
                } else if onDismiss != nil {
                    Spacer(minLength: 0)
                    dismissButton
                        .padding(.trailing, ReaderToastBarMetrics.horizontalContentPadding)
                }
            }
            .padding(.vertical, toastStyle == .bordered ? 2 : 0)
            .background(backgroundView)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    @ViewBuilder
    var inlineBody: some View {
        HStack(spacing: 8) {
            content
            if let trailingAccessory, shouldShowTrailingAccessory {
                trailingAccessory
            } else if onDismiss != nil {
                dismissButton
            }
        }
    }

    @ViewBuilder
    var backgroundView: some View {
        switch toastStyle {
        case .bordered:
            Capsule()
                .fill(.regularMaterial)
                .shadow(radius: 2)
        case .borderless:
            Color.clear
        }
    }
    
    @ViewBuilder
    var dismissButton: some View {
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
    
    private var shouldShowTrailingAccessory: Bool {
        !(controlSize == .small || controlSize == .mini)
    }
}
