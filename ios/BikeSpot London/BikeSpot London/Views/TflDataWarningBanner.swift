import SwiftUI

struct TflDataWarningBanner: View {
    let message: String
    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.body)

            Text(message)
                .font(.body)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                showingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
        )
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        .alert("TfL Data Feed Issue", isPresented: $showingInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The Transport for London (TfL) bike data feed appears to be returning outdated information.\n\nThis is an issue with the TfL data feed, not with this app. Dock availability shown may not reflect current conditions.\n\nPlease check back later for updated information.")
        }
    }
}
