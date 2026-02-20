//
//  EmptyWidgetView.swift
//  My Boris Bikes Widget
//
//  Empty state view for when there are no favourites
//

import SwiftUI

struct EmptyWidgetView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bicycle.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Open the app to add favourites")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    EmptyWidgetView(message: "No favourites")
}
