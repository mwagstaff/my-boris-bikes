import SwiftUI

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color(.systemGroupedBackground)
    }

    private var cardColor: Color {
        colorScheme == .dark ? Color(white: 0.14) : Color(.secondarySystemBackground)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.12)
    }

    private var sectionHeaderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary
    }

    private var linkColor: Color {
        colorScheme == .dark ? Color(red: 0.28, green: 0.62, blue: 1.0) : Color.blue
    }

    private let feedbackURL = URL(string: "mailto:mike.wagstaff@gmail.com?subject=My%20Boris%20Bikes%20feedback")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("About")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.top, 6)

                AboutCard(background: cardColor, stroke: cardStroke, shadow: cardShadow) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("My Boris Bikes")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Version \(Bundle.main.appVersionString)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Quickly find available Santander Cycles (a.k.a. \"Boris Bikes\") and free dock spaces across London on your iPad, Phone or Watch.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }

                SectionHeader("Developer", color: sectionHeaderColor)

                AboutCard(background: cardColor, stroke: cardStroke, shadow: cardShadow) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Developed by Mike Wagstaff")
                            .font(.body)

                        Divider()
                            .overlay(cardStroke)

                        Link(destination: URL(string: AppConstants.App.developerURL)!) {
                            Label("Sky No Limit", systemImage: "globe")
                                .font(.headline)
                        }
                        .foregroundColor(linkColor)
                    }
                }

                SectionHeader("Feedback", color: sectionHeaderColor)

                AboutCard(background: cardColor, stroke: cardStroke, shadow: cardShadow) {
                    Link(destination: feedbackURL) {
                        Label("Email Feedback", systemImage: "envelope")
                            .font(.headline)
                    }
                    .foregroundColor(linkColor)
                }

                SectionHeader("Data sources", color: sectionHeaderColor)

                AboutCard(background: cardColor, stroke: cardStroke, shadow: cardShadow) {
                    Link(destination: URL(string: "https://tfl.gov.uk")!) {
                        Label("Transport for London", systemImage: "folder")
                            .font(.headline)
                    }
                    .foregroundColor(linkColor)
                }

                Text("Note: This app is not affiliated with TfL or Santander. To hire a bike, please use the official [Santander Cycles app](https://apps.apple.com/gb/app/santander-cycles/id974792287) or the dock terminal.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(backgroundColor.ignoresSafeArea())
    }
}

private struct SectionHeader: View {
    private let title: String
    private let color: Color

    init(_ title: String, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundColor(color)
            .padding(.top, 4)
    }
}

private struct AboutCard<Content: View>: View {
    let background: Color
    let stroke: Color
    let shadow: Color
    let content: Content

    init(background: Color, stroke: Color, shadow: Color, @ViewBuilder content: () -> Content) {
        self.background = background
        self.stroke = stroke
        self.shadow = shadow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                )
        )
        .shadow(color: shadow, radius: 8, x: 0, y: 4)
    }
}

#Preview {
    AboutView()
}
