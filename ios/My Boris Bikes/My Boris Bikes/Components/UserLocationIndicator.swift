import SwiftUI

struct UserLocationIndicator: View {
    @State private var pulseAnimation = false
    
    var body: some View {
        ZStack {
            // Outer pulsing ring
            Circle()
                .fill(Color.blue.opacity(0.3))
                .frame(width: 30, height: 30)
                .scaleEffect(pulseAnimation ? 1.5 : 1.0)
                .opacity(pulseAnimation ? 0.0 : 0.6)
                .animation(
                    Animation.easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: false),
                    value: pulseAnimation
                )
            
            // Inner solid dot with white border
            Circle()
                .fill(Color.blue)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 12, height: 12)
                )
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
        }
        .onAppear {
            pulseAnimation = true
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()
        
        UserLocationIndicator()
    }
}