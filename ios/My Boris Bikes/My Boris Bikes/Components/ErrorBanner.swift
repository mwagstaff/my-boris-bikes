import SwiftUI

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    @State private var isVisible = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection Issue")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
        )
        .overlay(
            Rectangle()
                .frame(height: 3)
                .foregroundColor(.orange)
                .opacity(0.8),
            alignment: .top
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .offset(y: isVisible ? 0 : -100)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isVisible = true
            }
            
            // Auto-dismiss after 10 seconds if user doesn't manually dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if isVisible {
                    dismissBanner()
                }
            }
        }
        .onTapGesture {
            dismissBanner()
        }
    }
    
    private func dismissBanner() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isVisible = false
        }
        
        // Call onDismiss after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onDismiss()
        }
    }
}

#Preview {
    VStack {
        ErrorBanner(
            message: "Data parsing error: The data couldn't be read because it is missing",
            onDismiss: {}
        )
        
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.1))
}