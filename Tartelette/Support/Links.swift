import Foundation

/// External documentation linked from Help and onboarding.
nonisolated enum Links {
  static let tartDocumentation = URL(string: "https://tart.run")!
  /// Tart's license, FSL-1.1-ALv2, which covers the copy Tartelette downloads.
  static let tartLicense = URL(string: "https://github.com/openai/tart/blob/main/LICENSE")!
  /// Tart and its guest agent are maintained under the OpenAI GitHub organisation; Cirrus Labs
  /// still publishes the VM images (ghcr.io/cirruslabs).
  static let guestAgent = URL(string: "https://github.com/openai/tart-guest-agent")!
  /// Installs Tart with Homebrew (tap `openai/tools`). Homebrew 6 refuses formulae from third-party
  /// taps until they are trusted, and installing by full name trusts only that formula, not its
  /// Softnet dependency from the same tap.
  static let homebrewInstallCommand =
    "brew trust --formula openai/tools/tart openai/tools/softnet && brew install openai/tools/tart"
  /// Installs Tart from its release archive into /Applications/tart.app, where Tartelette finds it.
  /// Needed on macOS 14: the Homebrew formula depends on Softnet, which requires macOS 15.
  static let archiveInstallCommand =
    "curl -fL https://github.com/openai/tart/releases/latest/download/tart.tar.gz | tar -xz -C /Applications"
  /// Installs Softnet (`--net-softnet`) from the tap Tart comes from; naming the formula in full
  /// trusts it.
  static let softnetInstallCommand = "brew install openai/tools/softnet"
  /// Updates a Tart installed with Homebrew, which Tartelette doesn't update itself.
  static let homebrewUpgradeCommand = "brew upgrade openai/tools/tart"

  static var canInstallTartWithHomebrew: Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
  }

  /// The install command that works on this Mac.
  static var installCommand: String { canInstallTartWithHomebrew ? homebrewInstallCommand : archiveInstallCommand }
  static let images = URL(string: "https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos")!

  static let repository = URL(string: "https://github.com/lacrimae0rerum/tartelette")!
  static let releases = URL(string: "https://github.com/lacrimae0rerum/tartelette/releases")!
  static let issues = URL(string: "https://github.com/lacrimae0rerum/tartelette/issues")!
}
