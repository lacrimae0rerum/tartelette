import SwiftUI
import TarteletteKit

/// Visual vocabulary for VM states and operating systems.
extension VMState {
  var title: String {
    switch self {
    case .running: "Running"
    case .suspended: "Suspended"
    case .stopped: "Stopped"
    case .unknown(let value): value.capitalized
    }
  }

  var tint: Color {
    switch self {
    case .running: .green
    case .suspended: .orange
    case .stopped: .secondary
    case .unknown: .gray
    }
  }

  var systemImage: String {
    switch self {
    case .running: "play.circle.fill"
    case .suspended: "pause.circle.fill"
    case .stopped: "stop.circle"
    case .unknown: "questionmark.circle"
    }
  }
}

extension VMOperatingSystem {
  var systemImage: String {
    switch self {
    case .macOS: "apple.logo"
    case .linux: "server.rack"
    case .unknown: "questionmark.square.dashed"
    }
  }

  /// Gradient used behind the OS glyph.
  var gradient: [Color] {
    switch self {
    case .macOS: [Color(red: 0.36, green: 0.40, blue: 0.95), Color(red: 0.20, green: 0.18, blue: 0.58)]
    case .linux: [Color(red: 0.98, green: 0.62, blue: 0.24), Color(red: 0.86, green: 0.34, blue: 0.20)]
    case .unknown: [Color.gray, Color.gray.opacity(0.7)]
    }
  }
}

extension MemoryPressure {
  var title: String {
    switch self {
    case .normal: "Normal"
    case .warning: "Elevated"
    case .critical: "Critical"
    }
  }

  var tint: Color {
    switch self {
    case .normal: .green
    case .warning: .yellow
    case .critical: .red
    }
  }
}

extension HostThermalState {
  var title: String {
    switch self {
    case .nominal: "Nominal"
    case .fair: "Fair"
    case .serious: "Serious"
    case .critical: "Critical"
    }
  }

  var tint: Color {
    switch self {
    case .nominal: .green
    case .fair: .yellow
    case .serious: .orange
    case .critical: .red
    }
  }
}

extension GuestAgentStatus {
  var title: String {
    switch self {
    case .unknown: "Not checked"
    case .checking: "Checking…"
    case .available: "Connected"
    case .unavailable: "Unavailable"
    }
  }

  var detail: String {
    switch self {
    case .unknown: "The guest agent is checked automatically after the VM starts."
    case .checking: "Contacting the Tart Guest Agent…"
    case .available(let user, let isRoot):
      isRoot ? "Commands run as root (\(user))." : "Commands run as “\(user)”."
    case .unavailable(let reason): reason
    }
  }

  var tint: Color {
    switch self {
    case .unknown: .secondary
    case .checking: .blue
    case .available: .green
    case .unavailable: .orange
    }
  }

  var systemImage: String {
    switch self {
    case .unknown: "circle.dashed"
    case .checking: "arrow.triangle.2.circlepath"
    case .available: "checkmark.circle.fill"
    case .unavailable: "exclamationmark.triangle.fill"
    }
  }
}
