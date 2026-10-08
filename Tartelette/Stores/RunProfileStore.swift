import Foundation
import Observation
import TarteletteKit

/// How host↔guest copy and paste works for a VM.
nonisolated enum ClipboardEngine: String, Codable, CaseIterable, Identifiable, Sendable {
  /// Bridge for macOS guests, Tart's SPICE agent for Linux guests.
  case automatic
  /// Tartelette's bridge over `tart exec`: rich text, images and files, verified transfers.
  /// VMs start with `--no-clipboard` so Tart's text-only agent can't clobber rich content.
  case bridge
  /// Tart's built-in SPICE clipboard (text only; needs the guest agent or spice-vdagent).
  case spice
  /// No clipboard sharing (`--no-clipboard`).
  case off

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .bridge: "Tartelette Bridge"
    case .spice: "Tart (SPICE)"
    case .off: "Off"
    }
  }

  var summary: String {
    switch self {
    case .automatic: "Bridge for macOS guests, Tart's agent for Linux guests."
    case .bridge: "Text, rich text, images and files in both directions."
    case .spice: "Plain text through Tart's built-in agent."
    case .off: "Clipboard sharing is disabled."
    }
  }

  /// The concrete engine for a guest OS.
  func resolved(for os: VMOperatingSystem) -> ClipboardEngine {
    guard self == .automatic else { return self }
    return os == .macOS ? .bridge : .spice
  }
}

/// Everything Tartelette remembers about how to start one VM.
nonisolated struct RunProfile: Codable, Equatable, Sendable {
  var options: RunOptions
  var clipboardEngine: ClipboardEngine
  var ipResolver: IPOptions.Resolver
  /// Seconds `tart stop` waits before forcing the VM off.
  var stopTimeout: Int

  init(
    options: RunOptions,
    clipboardEngine: ClipboardEngine = .automatic,
    ipResolver: IPOptions.Resolver = .dhcp,
    stopTimeout: Int = TartCommand.defaultStopTimeoutSeconds
  ) {
    self.options = options
    self.clipboardEngine = clipboardEngine
    self.ipResolver = ipResolver
    self.stopTimeout = stopTimeout
  }
}

/// Per-VM run profiles, persisted as JSON in Application Support.
///
/// Sheets and the Run Options tab read `profile(for:)` and write with `update(_:_:)`;
/// `VMLibrary.start` turns the profile into `tart run` arguments.
@Observable
final class RunProfileStore {
  private(set) var profiles: [String: RunProfile] = [:]
  private let fileURL: URL
  private let defaultEngine: () -> ClipboardEngine

  init(fileURL: URL = RunProfileStore.defaultFileURL, defaultEngine: @escaping () -> ClipboardEngine) {
    self.fileURL = fileURL
    self.defaultEngine = defaultEngine
    load()
  }

  static var defaultFileURL: URL {
    URL.applicationSupportDirectory
      .appendingPathComponent("Tartelette", isDirectory: true)
      .appendingPathComponent("profiles.json")
  }

  /// The saved profile, or defaults (plain `tart run <name>`) when none was saved.
  func profile(for name: String) -> RunProfile {
    if var profile = profiles[name] {
      profile.options.name = name
      return profile
    }
    return RunProfile(options: RunOptions(name: name), clipboardEngine: defaultEngine())
  }

  func hasCustomProfile(_ name: String) -> Bool { profiles[name] != nil }

  func save(_ profile: RunProfile, for name: String) {
    var profile = profile
    profile.options.name = name
    profiles[name] = profile
    persist()
  }

  func update(_ name: String, _ transform: (inout RunProfile) -> Void) {
    var profile = profile(for: name)
    transform(&profile)
    save(profile, for: name)
  }

  func reset(_ name: String) {
    profiles[name] = nil
    persist()
  }

  func rename(from oldName: String, to newName: String) {
    guard let profile = profiles.removeValue(forKey: oldName) else { return }
    save(profile, for: newName)
  }

  func remove(_ name: String) {
    guard profiles.removeValue(forKey: name) != nil else { return }
    persist()
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode([String: RunProfile].self, from: data)
    else { return }
    profiles = decoded
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    } catch {
      NSLog("Tartelette: could not save run profiles: \(error.localizedDescription)")
    }
  }
}
