import SwiftUI

public struct AdblockStatsMenuItem: View {
    @ObservedObject private var statsModel: AdblockStatsModel
    private let isEnabled: Bool
    @State private var isPresented = false

    public init(statsModel: AdblockStatsModel, isEnabled: Bool = true) {
        self.statsModel = statsModel
        self.isEnabled = isEnabled
    }

    public var body: some View {
        Group {
            if isEnabled, statsModel.blockedCount > 0 {
                Button {
                    isPresented = true
                } label: {
                    Label(menuTitle(for: statsModel.blockedCount), systemImage: "shield")
                }
                .sheet(isPresented: $isPresented) {
                    AdblockStatsSheetView(statsModel: statsModel)
                }
            }
        }
    }

    private func menuTitle(for count: Int) -> String {
        if count == 1 {
            return "1 tracker or ad blocked"
        }
        return "\(count) trackers & ads blocked"
    }
}

public struct AdblockStatsSheetView: View {
    @ObservedObject private var statsModel: AdblockStatsModel
    @Environment(\.dismiss) private var dismiss
    @State private var expandedHosts: Set<String> = []

    public init(statsModel: AdblockStatsModel) {
        self.statsModel = statsModel
    }

    public var body: some View {
        if #available(iOS 16, macOS 13, *) {
            NavigationStack {
                content
            }
        } else {
            NavigationView {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let grouped = groupedRequests
        let totalCount = statsModel.blockedCount
        VStack(alignment: .leading, spacing: 12) {
            Text(summaryTitle(for: totalCount))
                .font(.title2.weight(.semibold))
                .padding(.horizontal)
                .padding(.top, 4)
            List {
                if grouped.singles.isEmpty && grouped.grouped.isEmpty {
                    Text("No blocked requests for this page.")
                        .foregroundStyle(.secondary)
                } else {
                    if !grouped.singles.isEmpty {
                        Section {
                            ForEach(grouped.singles) { request in
                                AdblockStatsURLRow(url: request.requestURL)
                            }
                        }
                    }
                    ForEach(grouped.grouped) { group in
                        Section {
                            if expandedHosts.contains(group.host) {
                                ForEach(group.requests) { request in
                                    AdblockStatsURLRow(url: request.requestURL)
                                }
                            }
                        } header: {
                            Button {
                                toggleExpanded(host: group.host)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: expandedHosts.contains(group.host) ? "minus" : "plus")
                                        .font(.caption.weight(.semibold))
                                    Text(group.host)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Trackers & ads blocked")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private struct HostGroup: Identifiable, Hashable {
        let host: String
        let requests: [AdblockBlockedRequest]

        var id: String { host }
    }

    private var groupedRequests: (singles: [AdblockBlockedRequest], grouped: [HostGroup]) {
        var singles: [AdblockBlockedRequest] = []
        var groups: [HostGroup] = []
        let groupedByHost = Dictionary(grouping: statsModel.blockedRequests) { request in
            request.requestURL.host ?? ""
        }

        for (host, requests) in groupedByHost {
            let sorted = requests.sorted { lhs, rhs in
                lhs.requestURL.absoluteString < rhs.requestURL.absoluteString
            }
            if host.isEmpty || sorted.count == 1 {
                singles.append(contentsOf: sorted)
            } else {
                groups.append(HostGroup(host: host, requests: sorted))
            }
        }

        singles.sort { lhs, rhs in
            lhs.requestURL.absoluteString < rhs.requestURL.absoluteString
        }
        groups.sort { lhs, rhs in
            lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
        }

        return (singles, groups)
    }

    private func summaryTitle(for count: Int) -> String {
        if count == 1 {
            return "1 Tracker & ad"
        }
        return "\(count) Trackers & ads"
    }

    private func toggleExpanded(host: String) {
        if expandedHosts.contains(host) {
            expandedHosts.remove(host)
        } else {
            expandedHosts.insert(host)
        }
    }
}

private struct AdblockStatsURLRow: View {
    let url: URL

    var body: some View {
        Text(url.absoluteString)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .font(.callout)
    }
}
