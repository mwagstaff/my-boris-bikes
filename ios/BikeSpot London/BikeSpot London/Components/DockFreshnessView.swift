import SwiftUI

/// Kept above the counts (and inside dock sheets) so cached data is never silently
/// presented as live while a foreground refresh or retry is in progress.
struct DockFreshnessView: View {
    @ObservedObject private var store = DockAvailabilityStore.shared
    var dockIDs: [String]? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if store.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting latest data…")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dock-data-refreshing")
                .statusStyle()
            } else if store.isStale(at: context.date, dockIDs: dockIDs) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                    Text(store.refreshFailed
                        ? "Couldn’t refresh. Dock data may be out of date."
                        : "Dock data may be out of date.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") { store.refresh(dockIDs: dockIDs ?? [], force: true) }
                }
                .accessibilityIdentifier("dock-data-stale")
                .statusStyle()
            }
        }
    }
}

private extension View {
    func statusStyle() -> some View {
        self.font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("Freshness · Large text") {
    DockFreshnessView().padding().environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Freshness · Dark") {
    DockFreshnessView().padding().preferredColorScheme(.dark)
}
