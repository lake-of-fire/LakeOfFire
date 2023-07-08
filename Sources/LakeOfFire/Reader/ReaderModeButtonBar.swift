import SwiftUI

struct ReaderModeButtonBar: View {
    let showReaderView: @MainActor () -> Void
    
    @State private var isCollapsed = false
    
    var body: some View {
        if isCollapsed {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Button {
                        isCollapsed = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .padding(10)
                    }
                    .buttonStyle(.borderless)
                }
                .background(.ultraThinMaterial)
            }
        } else {
            ZStack {
                Button {
                    showReaderView()
                } label: {
                    Text("Reader Mode")
#if os(iOS)
                        .font(.headline)
#endif
                        .padding(5)
                }
                .padding(.horizontal, 44)
                .buttonStyle(.borderedProminent)
                .padding(10)
                
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        isCollapsed = true
                    } label: {
                        Image(systemName: "chevron.down")
                            .padding(10)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
    }
}
