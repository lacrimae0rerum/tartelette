import SwiftUI
import TarteletteKit

/// A rounded, gradient-filled glyph for a guest operating system.
struct OSIcon: View {
  let os: VMOperatingSystem
  var size: CGFloat = 28

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(LinearGradient(colors: os.gradient, startPoint: .top, endPoint: .bottom))
      .overlay(
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
          .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
      )
      .overlay {
        Image(systemName: os.systemImage)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
      }
      .frame(width: size, height: size)
      .shadow(color: os.gradient.last?.opacity(0.25) ?? .clear, radius: size * 0.08, y: size * 0.04)
      .accessibilityLabel(os.displayName)
  }
}
