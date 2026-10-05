import SwiftUI

enum BikeSpotStyle {
    static let canvas = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)

    static func availabilityColor(count: Int, threshold: Int) -> Color {
        Color(count == 0 ? "AvailabilityEmpty" : count < threshold ? "AvailabilityLow" : "AvailabilityGood")
    }
}

/// Photography stays in the header; scrolling content has a quiet, adaptive canvas.
struct BikeSpotBackground: View {
    var showsPhoto = true
    @State private var backgrounds = LondonBackgroundService.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                BikeSpotStyle.canvas
                if showsPhoto && !reduceTransparency && contrast != .increased {
                    backgroundImage
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: 320, alignment: .trailing)
                        .clipped()
                        .opacity(colorScheme == .dark ? 0.72 : 0.34)
                        .mask {
                            LinearGradient(
                                stops: photoMaskStops,
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backgroundImage: Image {
        if let image = backgrounds.image {
            return Image(decorative: image, scale: 1)
        }
        return Image(backgrounds.bundledImageName)
    }

    private var photoMaskStops: [Gradient.Stop] {
        if colorScheme == .dark {
            return [.init(color: .black, location: 0),
                    .init(color: .black, location: 0.55),
                    .init(color: .black.opacity(0.85), location: 0.8),
                    .init(color: .clear, location: 1)]
        }
        return [.init(color: .black, location: 0),
                .init(color: .black.opacity(0.7), location: 0.45),
                .init(color: .clear, location: 1)]
    }
}

extension View {
    func bikeSpotBackground(showsPhoto: Bool = true) -> some View {
        scrollContentBackground(.hidden)
            .background { BikeSpotBackground(showsPhoto: showsPhoto) }
    }

    func bikeSpotCard() -> some View {
        background(BikeSpotStyle.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    func bikeSpotFloatingControl() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}

struct AvailabilityPill: View {
    let count: Int?
    let label: String
    let symbol: String
    let threshold: Int

    private var color: Color {
        count.map { BikeSpotStyle.availabilityColor(count: $0, threshold: threshold) } ?? .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(count.map { "\($0) \(label)" } ?? "Unavailable")
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\($0) \(label), \($0 == 0 ? "none available" : $0 < threshold ? "low availability" : "available")" } ?? "\(label) availability unavailable")
    }
}

/// Wrap pills at larger text sizes instead of shrinking their text.
struct AvailabilityPillLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = positions(for: subviews, width: proposal.width ?? .infinity)
        return layout.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(for: subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let frame = layout.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func positions(for subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            // Measure the complete chip once. Narrow proposals must wrap chips,
            // never collapse a label into an icon or a tall column of text.
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
}

#Preview("Availability · Light") {
    VStack(alignment: .leading, spacing: 20) {
        Text("Your next ride").font(.largeTitle.bold())
        AvailabilityPillLayout {
            AvailabilityPill(count: 0, label: "bikes", symbol: "bicycle", threshold: 5)
            AvailabilityPill(count: 3, label: "e-bikes", symbol: "bolt.fill", threshold: 5)
            AvailabilityPill(count: 19, label: "spaces", symbol: "parkingsign.circle", threshold: 5)
        }
        .padding().bikeSpotCard()
        Spacer()
    }
    .padding().bikeSpotBackground()
}

#Preview("Availability · Dark & Large Text") {
    AvailabilityPillLayout {
        AvailabilityPill(count: 0, label: "bikes", symbol: "bicycle", threshold: 5)
        AvailabilityPill(count: 3, label: "e-bikes", symbol: "bolt.fill", threshold: 5)
        AvailabilityPill(count: 19, label: "spaces", symbol: "parkingsign.circle", threshold: 5)
    }
    .padding().bikeSpotCard().padding().bikeSpotBackground()
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Availability · Narrow dock button") {
    Button {} label: {
        VStack(alignment: .leading, spacing: 8) {
            Text("Station").font(.headline)
            AvailabilityPillLayout {
                AvailabilityPill(count: 1, label: "bike", symbol: "bicycle", threshold: 3)
                AvailabilityPill(count: 17, label: "spaces", symbol: "parkingsign.circle", threshold: 3)
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding().bikeSpotCard()
    }
    .buttonStyle(.plain)
    .labelStyle(.iconOnly)
    .padding().bikeSpotBackground()
}
