import SwiftUI

struct ServiceStatusButton: View {
    let severity: BannerConfig.BannerSeverity
    let action: () -> Void

    private var iconColor: Color {
        switch severity {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var iconName: String {
        switch severity {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundColor(iconColor)
        }
    }
}

#Preview {
    HStack {
        ServiceStatusButton(severity: .error) {}
        ServiceStatusButton(severity: .warning) {}
        ServiceStatusButton(severity: .info) {}
    }
}
