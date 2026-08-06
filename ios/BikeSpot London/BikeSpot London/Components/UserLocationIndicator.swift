import SwiftUI
import CoreLocation

private struct HeadingConeShape: Shape {
    var coneAngle: Double = 55
    
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle.degrees(-90 - (coneAngle / 2))
        let endAngle = Angle.degrees(-90 + (coneAngle / 2))
        
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

struct UserLocationIndicator: View {
    let heading: CLLocationDirection?
    @State private var pulseAnimation = false
    @State private var displayedHeading: Double?
    
    var body: some View {
        ZStack {
            if let displayedHeading {
                HeadingConeShape()
                    .fill(Color.blue.opacity(0.22))
                    .frame(width: 54, height: 54)
                    .rotationEffect(.degrees(displayedHeading))
            }

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
            updateDisplayedHeading(with: heading, animated: false)
        }
        .onChange(of: heading) { _, newHeading in
            updateDisplayedHeading(with: newHeading, animated: true)
        }
    }

    private func updateDisplayedHeading(with newHeading: CLLocationDirection?, animated: Bool) {
        guard let newHeading else { return }
        let normalizedNewHeading = normalize(newHeading)

        guard let currentHeading = displayedHeading else {
            displayedHeading = normalizedNewHeading
            return
        }

        let delta = shortestAngularDelta(
            from: normalize(currentHeading),
            to: normalizedNewHeading
        )

        // Ignore tiny jitter from the compass sensor.
        if abs(delta) < 0.8 { return }

        let targetHeading = currentHeading + delta

        if animated {
            // Short, adaptive duration keeps the cone responsive while still smoothing jumps.
            let duration = animationDuration(for: delta)
            withAnimation(.easeInOut(duration: duration)) {
                displayedHeading = targetHeading
            }
        } else {
            displayedHeading = targetHeading
        }
    }

    private func shortestAngularDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func normalize(_ angle: Double) -> Double {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private func animationDuration(for delta: Double) -> Double {
        let magnitude = abs(delta)
        return min(0.30, max(0.14, magnitude / 360))
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()
        
        UserLocationIndicator(heading: 35)
    }
}
