import Foundation
import Observation
import TarteletteKit

/// The detected Tart installation shared by every store.
///
/// `client` is nil until `tart` is found; screens then show onboarding.
@Observable
final class TartContext {
  private(set) var environment: TartEnvironment?
  private(set) var client: TartClient?
  private(set) var version: String?
  private(set) var capabilities: TartCapabilities = .unknown
  let runner = ProcessRunner()

  var isAvailable: Bool { client != nil }
  var paths: TartPaths { environment?.paths ?? .resolve() }

  /// Re-detects `tart` with the current settings. Returns true when the environment changed.
  @discardableResult
  func reload(settings: AppSettings) -> Bool {
    var detected = TartEnvironment.detect(
      preferredExecutablePath: settings.tartExecutablePath,
      tartHome: settings.tartHome
    )
    detected?.extraVariables = settings.tartVariables
    guard detected != environment else { return false }
    environment = detected
    client = detected.map { TartClient(environment: $0, runner: runner) }
    version = nil
    capabilities = .unknown
    if let client {
      Task {
        let version = try? await client.version()
        let capabilities = await client.capabilities()
        guard self.client === client else { return }
        self.version = version
        self.capabilities = capabilities
      }
    }
    return true
  }

  /// The `tart` path quoted for shell command lines (Terminal launches).
  var quotedExecutable: String {
    ShellQuoting.quote(environment?.executable.path ?? "tart")
  }
}
