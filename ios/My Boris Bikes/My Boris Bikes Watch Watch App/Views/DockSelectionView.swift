//
//  DockSelectionView.swift
//  My Boris Bikes Watch Watch App
//
//  Created by Mike Wagstaff on 11/08/2025.
//

import SwiftUI
import WidgetKit

struct DockSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var favoritesService = WatchFavoritesService.shared
    
    // Callback to notify parent with selected dock data for navigation
    var onDockSelected: ((WatchFavoriteBikePoint, Bool) -> Void)?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if favoritesService.favorites.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "heart.slash")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        
                        Text("No Favorites")
                            .font(.headline)
                        
                        Text("Add favorites on your iPhone to configure this widget")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            ForEach(sortedFavorites, id: \.id) { favorite in
                                DockSelectionButton(
                                    favorite: favorite,
                                    onTap: {
                                        selectDockAndReturn(favorite)
                                    }
                                )
                            }
                        } header: {
                            Text("Choose a dock...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Widget Dock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var sortedFavorites: [WatchFavoriteBikePoint] {
        favoritesService.favorites.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    
    private func selectDockAndReturn(_ favorite: WatchFavoriteBikePoint) {
        
        // Check if there's a pending widget configuration
        guard let pendingWidgetId = InteractiveDockWidgetManager.shared.getPendingConfiguration() else {
            dismiss()
            return
        }
        
        // Configure the widget immediately
        InteractiveDockWidgetManager.shared.setSelectedDockId(favorite.id, for: pendingWidgetId)
        
        // Provide haptic feedback
        WKInterfaceDevice.current().play(.success)
        
        // Reload widget timelines to show updated configuration
        WidgetCenter.shared.reloadAllTimelines()
        
        
        
        // Check if callback exists
        if onDockSelected != nil {
        } else {
        }
        
        // Dismiss sheet and notify parent to navigate to the selected dock with force refresh
        dismiss()
        onDockSelected?(favorite, true)
    }
}

struct RedButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(Color(red: 1, green: 0, blue: 0))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

struct DockSelectionButton: View {
    let favorite: WatchFavoriteBikePoint
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                if let alias = favorite.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !alias.isEmpty {
                    Text(alias)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(1)
                    Text(favorite.commonName)
                        .font(.system(.caption2))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                } else {
                    Text(favorite.commonName)
                        .font(.system(.caption, design: .default, weight: .medium))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(.white)
        .background(Color.red)
        .cornerRadius(5)
    }
}

#Preview {
    DockSelectionView(onDockSelected: { _, _ in })
}
