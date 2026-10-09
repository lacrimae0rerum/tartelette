import Foundation
import Observation
import ServiceManagement
import TarteletteKit

/// User preferences, persisted in `UserDefaults` (secrets in the Keychain).
///
/// Every property writes through on change, so views can bind to them directly:
/// `Toggle("Show in menu bar", isOn: $settings.showMenuBarExtra)`.
@Observable
final class AppSettings {
  private let defaults: UserDefaults
  private let secrets: any SecretStore

  static let sshService = "io.github.lacrimae0rerum.Tartelette.ssh"
  static let registryService = "io.github.lacrimae0rerum.Tartelette.registry"

  // MARK: General

  /// A user-chosen `tart` executable; nil means auto-detect.
  var tartExecutablePath: String? { didSet { store(tartExecutablePath, "tartExecutablePath") } }
  /// A custom `TART_HOME`; nil means `$TART_HOME` or `~/.tart`.
  var tartHome: String? { didSet { store(tartHome, "tartHome") } }
  /// Seconds between `tart list` refreshes while the app is active.
  var refreshInterval: Double { didSet { store(refreshInterval, "refreshInterval") } }
  var showMenuBarExtra: Bool { didSet { store(showMenuBarExtra, "showMenuBarExtra") } }
  /// Ask VMs started by Tartelette to shut down when the app quits.
  var stopVMsOnQuit: Bool { didSet { store(stopVMsOnQuit, "stopVMsOnQuit") } }
  var notifyOnCompletion: Bool { didSet { store(notifyOnCompletion, "notifyOnCompletion") } }

  // MARK: Monitoring

  /// Seconds between metric samples.
  var metricsInterval: Double { didSet { store(metricsInterval, "metricsInterval") } }
  /// Minutes of metric history kept in memory.
  var historyMinutes: Int { didSet { store(historyMinutes, "historyMinutes") } }
  var guestMetricsEnabled: Bool { didSet { store(guestMetricsEnabled, "guestMetricsEnabled") } }

  // MARK: Clipboard

  var defaultClipboardEngine: ClipboardEngine {
    didSet { store(defaultClipboardEngine.rawValue, "defaultClipboardEngine") }
  }
  var liveSyncByDefault: Bool { didSet { store(liveSyncByDefault, "liveSyncByDefault") } }
  var maxAutoTransferMB: Int { didSet { store(maxAutoTransferMB, "maxAutoTransferMB") } }
  var syncFiles: Bool { didSet { store(syncFiles, "syncFiles") } }
  /// SSH fallback (guests without the Tart Guest Agent). Cirrus Labs images use admin/admin.
  var sshUsername: String { didSet { store(sshUsername, "sshUsername") } }
  var sshPassword: String {
    didSet { secrets.write(sshPassword, service: Self.sshService) }
  }

  // MARK: Registries & network

  /// Sets `TART_NO_AUTO_PRUNE` so pulls and clones never prune caches automatically.
  var disableAutoPrune: Bool { didSet { store(disableAutoPrune, "disableAutoPrune") } }
  var registryUsername: String { didSet { store(registryUsername, "registryUsername") } }
  var registryHostname: String { didSet { store(registryHostname, "registryHostname") } }
  var registryPassword: String {
    didSet { secrets.write(registryPassword, service: Self.registryService) }
  }

  // MARK: Launch at login

  /// Mirrors `SMAppService.mainApp`; `launchAtLoginError` explains failures (e.g. unsigned builds).
  private(set) var launchAtLogin: Bool
  private(set) var launchAtLoginError: String?

  init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
    self.defaults = defaults
    self.secrets = secrets
    func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "settings." + key) as? T ?? fallback }

    tartExecutablePath = defaults.string(forKey: "settings.tartExecutablePath")
    tartHome = defaults.string(forKey: "settings.tartHome")
    refreshInterval = value("refreshInterval", 3.0)
    showMenuBarExtra = value("showMenuBarExtra", true)
    stopVMsOnQuit = value("stopVMsOnQuit", false)
    notifyOnCompletion = value("notifyOnCompletion", true)
    metricsInterval = value("metricsInterval", 1.0)
    historyMinutes = value("historyMinutes", 15)
    guestMetricsEnabled = value("guestMetricsEnabled", true)
    defaultClipboardEngine = ClipboardEngine(rawValue: value("defaultClipboardEngine", "automatic")) ?? .automatic
    liveSyncByDefault = value("liveSyncByDefault", true)
    maxAutoTransferMB = value("maxAutoTransferMB", 50)
    syncFiles = value("syncFiles", true)
    sshUsername = value("sshUsername", CatalogImage.defaultUsername)
    sshPassword = secrets.read(service: Self.sshService) ?? ""
    disableAutoPrune = value("disableAutoPrune", false)
    registryUsername = value("registryUsername", "")
    registryHostname = value("registryHostname", "")
    registryPassword = secrets.read(service: Self.registryService) ?? ""
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  /// Extra variables passed to every `tart` invocation.
  var tartVariables: [String: String] {
    var variables: [String: String] = [:]
    if disableAutoPrune { variables["TART_NO_AUTO_PRUNE"] = "1" }
    if !registryUsername.isEmpty, !registryPassword.isEmpty {
      variables["TART_REGISTRY_USERNAME"] = registryUsername
      variables["TART_REGISTRY_PASSWORD"] = registryPassword
      if !registryHostname.isEmpty { variables["TART_REGISTRY_HOSTNAME"] = registryHostname }
    }
    return variables
  }

  /// Password used for SSH fallback; Cirrus Labs images default to “admin”.
  var effectiveSSHPassword: String { sshPassword.isEmpty ? CatalogImage.defaultPassword : sshPassword }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginError = nil
    } catch {
      launchAtLoginError = error.localizedDescription
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  private func store(_ value: Any?, _ key: String) {
    if let value {
      defaults.set(value, forKey: "settings." + key)
    } else {
      defaults.removeObject(forKey: "settings." + key)
    }
  }
}
