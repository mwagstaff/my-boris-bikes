import SwiftUI

struct WidgetRefreshStatusView: View {
    let lastRefresh: Date?
    var warningThreshold: TimeInterval = 600

    private var isStale: Bool {
        guard let lastRefresh else { return false }
        return Date().timeIntervalSince(lastRefresh) > warningThreshold
    }

    private var textColor: Color {
        isStale ? .orange : .secondary
    }

    private var refreshText: String? {
        guard let lastRefresh else { return nil }

        let elapsed = Date().timeIntervalSince(lastRefresh)
        if elapsed >= 3600 {
            return "Updated >1 hour ago"
        }

        let minutes = Int(elapsed / 60)
        if minutes <= 0 {
            return "Updated <1 min ago"
        }
        if minutes == 1 {
            return "Updated 1 min ago"
        }
        return "Updated \(minutes) mins ago"
    }

    var body: some View {
        if let refreshText {
            HStack(spacing: 4) {
                if isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Text(refreshText)
                    .font(.caption2)
                    .foregroundColor(textColor)
            }
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        WidgetRefreshStatusView(lastRefresh: Date().addingTimeInterval(-120))
        WidgetRefreshStatusView(lastRefresh: Date().addingTimeInterval(-1200))
    }
}
