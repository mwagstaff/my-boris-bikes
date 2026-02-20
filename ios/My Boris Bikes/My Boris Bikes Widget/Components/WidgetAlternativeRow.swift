import SwiftUI

struct WidgetAlternativeRow: View {
    let alternatives: [WidgetBikePointData]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(alternatives.prefix(3))) { bikePoint in
                Link(destination: URL(string: "myborisbikes://dock/\(bikePoint.id)")!) {
                    VStack(spacing: 10) {
                        WidgetDonutChart(
                            standardBikes: bikePoint.standardBikes,
                            eBikes: bikePoint.eBikes,
                            emptySpaces: bikePoint.emptySpaces,
                            size: 28,
                            strokeWidth: 7
                        )

                        Text(shortenedName(from: bikePoint.displayName))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
    }

    private func shortenedName(from name: String) -> String {
        let trimmed = name.split(separator: ",").first.map(String.init) ?? name
        let words = trimmed.split(separator: " ")
        if words.count >= 2 {
            let twoWords = "\(words[0]) \(words[1])"
            return truncate(twoWords, maxLength: 14)
        }
        return truncate(trimmed, maxLength: 14)
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<index]) + "..."
    }
}

#Preview {
    WidgetAlternativeRow(
        alternatives: [
            WidgetBikePointData(
                id: "1",
                displayName: "Eaton Square (South)",
                actualName: "Eaton Square (South), Belgravia",
                standardBikes: 27,
                eBikes: 0,
                emptySpaces: 4,
                distance: 250,
                lastUpdated: Date(),
                isAlternative: true,
                parentFavoriteId: "fav1"
            ),
            WidgetBikePointData(
                id: "2",
                displayName: "Knightsbridge",
                actualName: "Knightsbridge, Hyde Park",
                standardBikes: 22,
                eBikes: 0,
                emptySpaces: 20,
                distance: 450,
                lastUpdated: Date(),
                isAlternative: true,
                parentFavoriteId: "fav1"
            ),
            WidgetBikePointData(
                id: "3",
                displayName: "Fire Brigade Pier",
                actualName: "Fire Brigade Pier, Vauxhall",
                standardBikes: 22,
                eBikes: 0,
                emptySpaces: 7,
                distance: 680,
                lastUpdated: Date(),
                isAlternative: true,
                parentFavoriteId: "fav1"
            )
        ]
    )
}
