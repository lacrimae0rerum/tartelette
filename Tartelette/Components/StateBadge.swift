import SwiftUI
import TarteletteKit

/// A small coloured dot that reflects a VM state. Pulses gently while running.
struct StatusDot: View {
  let state: VMState
  var size: CGFloat = 8

  var body: some View {
    Circle()
      .fill(state.tint)
      .frame(width: size, height: size)
      .overlay {
        if state.isRunning {
          Circle()
            .stroke(state.tint.opacity(0.35), lineWidth: 3)
            .frame(width: size + 4, height: size + 4)
        }
      }
      .accessibilityLabel(state.title)
  }
}

/// A capsule label such as “● Running”.
struct StateBadge: View {
  let state: VMState

  var body: some View {
    HStack(spacing: 5) {
      StatusDot(state: state, size: 7)
      Text(state.title)
        .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(state.tint.opacity(0.14), in: Capsule())
    .foregroundStyle(state.isRunning ? state.tint : .secondary)
    .accessibilityElement(children: .combine)
  }
}

/// A generic tinted pill (e.g. guest agent status, source badges).
struct Pill: View {
  let title: String
  var systemImage: String?
  var tint: Color = .secondary

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage).imageScale(.small) }
      Text(title).font(.caption.weight(.medium))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.14), in: Capsule())
    .foregroundStyle(tint)
    .accessibilityElement(children: .combine)
  }
}
