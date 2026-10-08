import Foundation
import Security

/// A registry identity Tart can authenticate with.
public struct RegistryAccount: Sendable, Hashable, Identifiable {
  public enum Source: String, Sendable, Hashable, CaseIterable {
    /// Saved by `tart login` in the login Keychain.
    case keychain
    /// Listed in `~/.docker/config.json` (`auths` or `credHelpers`).
    case dockerConfig
    /// `TART_REGISTRY_USERNAME` / `TART_REGISTRY_PASSWORD` (optionally scoped by `TART_REGISTRY_HOSTNAME`).
    case environment
  }

  public var id: String { "\(source.rawValue):\(host):\(username ?? "")" }
  public var host: String
  public var username: String?
  public var source: Source

  public init(host: String, username: String?, source: Source) {
    self.host = host
    self.username = username
    self.source = source
  }
}

/// Lists the registry credentials Tart will use, without ever reading a secret.
///
/// Tart checks credentials in this order: environment variables, Docker config, Keychain.
public enum RegistryCredentialStore {
  /// The Keychain label `tart login` uses for its internet-password items.
  public static let keychainLabel = "Tart Credentials"

  /// Every known account from all sources.
  public static func allAccounts(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [RegistryAccount] {
    environmentAccounts(environment: environment) + dockerConfigHosts(home: home) + keychainAccounts()
  }

  /// Accounts saved by `tart login`. Queries attributes only, so the Keychain never prompts.
  public static func keychainAccounts() -> [RegistryAccount] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassInternetPassword,
      kSecAttrLabel as String: keychainLabel,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return [] }

    let accounts = items.compactMap { item -> RegistryAccount? in
      guard let host = item[kSecAttrServer as String] as? String, !host.isEmpty else { return nil }
      return RegistryAccount(host: host, username: item[kSecAttrAccount as String] as? String, source: .keychain)
    }
    return deduplicated(accounts)
  }

  /// Registries configured in `~/.docker/config.json` (credential values are not read).
  public static func dockerConfigHosts(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [RegistryAccount] {
    let file = home.appendingPathComponent(".docker/config.json")
    guard let data = try? Data(contentsOf: file),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }

    let hosts = Set(
      ((config["auths"] as? [String: Any])?.keys.map { $0 } ?? [])
        + ((config["credHelpers"] as? [String: Any])?.keys.map { $0 } ?? [])
    )
    let accounts = hosts.map { host in
      RegistryAccount(host: normalizedHost(host), username: nil, source: .dockerConfig)
    }
    return deduplicated(accounts)
  }

  /// The account provided through `TART_REGISTRY_*` environment variables, if complete.
  /// The host is `*` when `TART_REGISTRY_HOSTNAME` is unset (the credentials apply to any registry).
  public static func environmentAccounts(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> [RegistryAccount]
  {
    guard let username = environment["TART_REGISTRY_USERNAME"], !username.isEmpty,
      environment["TART_REGISTRY_PASSWORD"]?.isEmpty == false
    else { return [] }
    let host = environment["TART_REGISTRY_HOSTNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "*"
    return [RegistryAccount(host: host, username: username, source: .environment)]
  }

  /// Docker keys may be URLs such as `https://index.docker.io/v1/`; reduce them to a host.
  static func normalizedHost(_ key: String) -> String {
    if let url = URL(string: key), let host = url.host {
      return url.port.map { "\(host):\($0)" } ?? host
    }
    return key
  }

  private static func deduplicated(_ accounts: [RegistryAccount]) -> [RegistryAccount] {
    var seen = Set<String>()
    return accounts
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
  }
}
