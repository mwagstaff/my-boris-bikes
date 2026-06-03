import SwiftUI

struct ProfileView: View {
    @State private var isShowingPreferences = false
    @State private var isShowingAbout = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProfileNavigationCard { route in
                        switch route {
                        case .preferences:
                            isShowingAbout = false
                            isShowingPreferences = true
                        case .about:
                            isShowingPreferences = false
                            isShowingAbout = true
                        }
                    }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Profile")
            .navigationDestination(isPresented: $isShowingPreferences) {
                PreferencesView()
            }
            .navigationDestination(isPresented: $isShowingAbout) {
                AboutView()
            }
        }
    }
}

private enum ProfileRoute {
    case preferences
    case about
}

private struct ProfileNavigationCard: View {
    let navigate: (ProfileRoute) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                navigate(.preferences)
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

            Button {
                navigate(.about)
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

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
    }
}
