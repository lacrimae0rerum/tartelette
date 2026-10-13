import Foundation
import TarteletteAgents
import TarteletteCLI

/// The Tart settings the user chose in Tartelette, read from the app's preferences so the helper
/// finds and runs Tart as the app does.
public struct TarteletteSettings: Sendable, Equatable {
  /// The app's preferences domain (its bundle identifier).
  public static let appDomain = "io.github.lacrimae0rerum.Tartelette"

  /// A user-chosen `tart` executable; nil means auto-detect.
  public var tartExecutablePath: String?
  /// A custom `TART_HOME`; nil means `$TART_HOME` or `~/.tart`.
  public var tartHome: String?
  /// Extra variables for every `tart` invocation. The app's registry credentials are left out:
  /// the password is in the Keychain, and agent tools never pull or push images.
  public var tartVariables: [String: String]

  public init(tartExecutablePath: String? = nil, tartHome: String? = nil, tartVariables: [String: String] = [:]) {
    self.tartExecutablePath = tartExecutablePath
    self.tartHome = tartHome
    self.tartVariables = tartVariables
  }

  /// Reads the settings the app stores under `settings.` keys; empty values mean "not set".
  public init(defaults: UserDefaults) {
    func text(_ key: String) -> String? {
      defaults.string(forKey: "settings." + key).flatMap { $0.isEmpty ? nil : $0 }
    }
    self.init(
      tartExecutablePath: text("tartExecutablePath"),
      tartHome: text("tartHome"),
      tartVariables: defaults.bool(forKey: "settings.disableAutoPrune") ? ["TART_NO_AUTO_PRUNE": "1"] : [:])
  }

  /// The app's preferences. Inside the app bundle the helper has the app's bundle identifier, which
  /// `UserDefaults(suiteName:)` doesn't accept, and `.standard` is already the app's domain.
  public static func appDefaults(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> UserDefaults {
    guard bundleIdentifier != appDomain, let defaults = UserDefaults(suiteName: appDomain) else { return .standard }
    return defaults
  }

  /// A toolbox for the Tart these settings point to, recording `clientName` in the audit log.
  ///
  /// - Throws: `AgentToolError.tartNotFound` when no `tart` executable can be found.
  public func makeToolbox(clientName: String?) throws -> AgentToolbox {
    guard var environment = TartEnvironment.detect(preferredExecutablePath: tartExecutablePath, tartHome: tartHome)
    else { throw AgentToolError.tartNotFound }
    environment.extraVariables = tartVariables
    return AgentToolbox(client: TartClient(environment: environment), clientName: clientName)
  }
}
