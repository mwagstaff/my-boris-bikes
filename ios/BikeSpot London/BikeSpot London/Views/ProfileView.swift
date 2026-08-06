import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var scheduledJourneyService: ScheduledJourneyService
    @State private var isShowingPreferences = false
    @State private var isShowingAbout = false

    private var showsHolidayMode: Bool {
        scheduledJourneyService.hasEnabledJourneys || scheduledJourneyService.isHolidayModeEnabled
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProfileNavigationCard(
                        showsHolidayMode: showsHolidayMode,
                        isHolidayModeEnabled: scheduledJourneyService.isHolidayModeEnabled,
                        onToggleHolidayMode: {
                            let enabled = !scheduledJourneyService.isHolidayModeEnabled
                            Task { await scheduledJourneyService.setHolidayMode(enabled) }
                        },
                        navigate: { route in
                            switch route {
                            case .preferences:
                                isShowingAbout = false
                                isShowingPreferences = true
                            case .about:
                                isShowingPreferences = false
                                isShowingAbout = true
                            }
                        }
                    )
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
    let showsHolidayMode: Bool
    let isHolidayModeEnabled: Bool
    let onToggleHolidayMode: () -> Void
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

            if showsHolidayMode {
                Divider()
                    .padding(.leading, 88)

                Button(action: onToggleHolidayMode) {
                    ProfileNavigationRow(
                        title: isHolidayModeEnabled ? "Holiday mode on" : "Holiday mode",
                        subtitle: isHolidayModeEnabled
                            ? "Scheduled journeys are paused. Tap to switch holiday mode off."
                            : "Take a break — while holiday mode is on, your scheduled journeys and their notifications and widgets are paused.",
                        systemImage: isHolidayModeEnabled ? "beach.umbrella.fill" : "beach.umbrella",
                        iconColor: isHolidayModeEnabled ? .orange : Color.accentColor,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
            }

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
    var iconColor: Color = Color.accentColor
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(iconColor)
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

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
    }
}
