import SwiftUI

struct ProfileView: View {

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProfileNavigationCard()
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Profile")
        }
    }
}

private struct ProfileNavigationCard: View {
    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                PreferencesView()
            } label: {
                ProfileNavigationRow(
                    title: "Preferences",
                    subtitle: "Notifications, Live Activity, journey sorting, and display settings.",
                    systemImage: "slider.horizontal.3"
                )
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.leading, 88)

            NavigationLink {
                AboutView()
            } label: {
                ProfileNavigationRow(
                    title: "About",
                    subtitle: "Version info, feedback, credits, and data sources.",
                    systemImage: "info.circle"
                )
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct ProfileNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
    }
}
