//
//  WatchLoadingView.swift
//  My Boris Bikes Watch Watch App
//
//  Created by Claude on 13/08/2025.
//

import SwiftUI

struct WatchLoadingView: View {
    let dockName: String
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Animated loading indicator
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                        .frame(width: 40, height: 40)
                    
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.red, lineWidth: 3)
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
                }
                
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Dock information
            VStack(spacing: 8) {
                Text("Refreshing data for:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text(dockName)
                    .font(.system(.caption, design: .default, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundColor(.primary)
            }
        }
        .padding()
        .onAppear {
            isAnimating = true
        }
    }
}

#Preview {
    WatchLoadingView(dockName: "Farringdon Street, Holborn")
}