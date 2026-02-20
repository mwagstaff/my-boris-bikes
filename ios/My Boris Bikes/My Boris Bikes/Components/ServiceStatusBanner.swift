import SwiftUI

struct ServiceStatusBanner: View {
    let banner: BannerConfig
    let onDismiss: () -> Void

    private var backgroundColor: Color {
        switch banner.severity {
        case .info:
            return Color.blue.opacity(0.1)
        case .warning:
            return Color.orange.opacity(0.1)
        case .error:
            return Color.red.opacity(0.1)
        }
    }

    private var iconColor: Color {
        switch banner.severity {
        case .info:
            return Color.blue
        case .warning:
            return Color.orange
        case .error:
            return Color.red
        }
    }

    private var iconName: String {
        switch banner.severity {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundColor(iconColor)

                VStack(alignment: .leading, spacing: 8) {
                    Text(banner.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(banner.message)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(backgroundColor)
    }
}

#Preview {
    VStack {
        ServiceStatusBanner(
            banner: BannerConfig(
                enabled: true,
                title: "TfL API disruption",
                message: "Data is currently unavailable due to a disruption in the TfL API. We have escalated the issue to TfL in the hope that they can resolve it as quickly as possible. We apologize for any inconvenience caused.",
                severity: .error,
                updatedAt: "2025-12-16T10:30:00Z"
            ),
            onDismiss: {}
        )

        ServiceStatusBanner(
            banner: BannerConfig(
                enabled: true,
                title: "Planned Maintenance",
                message: "The TfL API will undergo maintenance tonight from 2-4am. Data may be temporarily unavailable.",
                severity: .warning,
                updatedAt: "2025-12-16T10:30:00Z"
            ),
            onDismiss: {}
        )

        ServiceStatusBanner(
            banner: BannerConfig(
                enabled: true,
                title: "New Feature Available",
                message: "You can now sort your favorite docks by distance, alphabetically, or manually!",
                severity: .info,
                updatedAt: "2025-12-16T10:30:00Z"
            ),
            onDismiss: {}
        )

        Spacer()
    }
}
