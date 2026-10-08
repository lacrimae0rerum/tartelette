import Foundation

/// External documentation linked from Help and onboarding.
nonisolated enum Links {
  static let tartDocumentation = URL(string: "https://tart.run")!
  /// Tart and its guest agent are maintained under the OpenAI GitHub organisation; Cirrus Labs
  /// still publishes the VM images (ghcr.io/cirruslabs).
  static let guestAgent = URL(string: "https://github.com/openai/tart-guest-agent")!
  /// Tart's documented Homebrew install command (README "Installation"; tap `openai/tools`).
  static let installCommand = "brew install openai/tools/tart"
  static let images = URL(string: "https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos")!
}
