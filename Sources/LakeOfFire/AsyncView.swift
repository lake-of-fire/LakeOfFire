import SwiftUI
import AsyncView

fileprivate struct ErrorView: View {
    let error: Error
    let reloadAction: (() -> Void)?
    @State private var showingPopover = false

    var body: some View {
        VStack(spacing: 10) {
            Button(error.localizedDescription) {
                showingPopover = true
            }
#if os(iOS)
            .buttonStyle(.borderedProminent)
#else
            .buttonStyle(.link)
#endif
            .popover(isPresented: $showingPopover) {
                Text(String(NSString(string: "\(error)")))
                    .font(.caption)
                    .padding()
            }
            if let reloadAction = reloadAction {
                Button(
                    action: reloadAction,
                    label: {
                        Image(systemName: "arrow.clockwise")
                    }
                )
            }
        }
    }
}

public struct AsyncView<Success, Content: View>: View {
    @StateObject private var model: AsyncModel<Success>
    //@Binding private var showInitialContent: Bool
    private var showInitialContent: Bool
    private let content: (_ item: Success?) -> Content
    
    public var body: some View {
        Group {
            switch (model.result, showInitialContent) {
            case (.inProgress, true):
                content(nil)
            case (.empty, true):
                // This is a workaround: EmptyView doesn't work here because then one layer up
                // in AsyncModelView the task would not be executed... (? Is this still true?)
                content(nil)
                //            content(nil)
            case (.empty, false):
                // This is a workaround: EmptyView doesn't work here because then one layer up
                // in AsyncModelView the task would not be executed... (? Is this still true?)
                Text("")
            case (.inProgress, false):
                ProgressView()
                    .padding()
            case let (.success(value), _):
                content(value)
            case let (.failure(error), showInitialContent):
                if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled, showInitialContent {
                    content(nil)
                } else {
                    ErrorView(error: error, reloadAction: {
                        Task {
                            await model.load(forceRefreshRequested: true)
                        }
                    })
                }
            }
        }
        .onAppear {
            Task {
                await model.loadIfNeeded()
            }
        }
        .refreshable {
            await model.load(forceRefreshRequested: true)
        }
    }
}

public extension AsyncView {
    //init(operation: @escaping AsyncModel<Success>.AsyncOperation, showInitialContent: Binding<Bool>, @ViewBuilder content: @escaping (_ item: Success?) -> Content) {
    init(operation: @escaping AsyncModel<Success>.AsyncOperation, showInitialContent: Bool, @ViewBuilder content: @escaping (_ item: Success?) -> Content) {
        self.init(model: AsyncModel(asyncOperation: operation), showInitialContent: showInitialContent, content: content)
    }
}
