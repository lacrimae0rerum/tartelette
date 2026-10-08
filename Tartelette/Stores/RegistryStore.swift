import Foundation
import Observation
import TarteletteKit

/// Registry identities Tart can use (Keychain, Docker config, environment) and login/logout.
@Observable
final class RegistryStore {
  private(set) var accounts: [RegistryAccount] = []
  private let jobs: JobCenter
  private let settings: AppSettings

  init(jobs: JobCenter, settings: AppSettings) {
    self.jobs = jobs
    self.settings = settings
  }

  /// Re-reads accounts. Never reads secrets, so the Keychain doesn't prompt.
  func refresh() {
    var environment = ProcessInfo.processInfo.environment
    environment.merge(settings.tartVariables) { _, new in new }
    accounts = RegistryCredentialStore.allAccounts(environment: environment)
  }

  /// `tart login <host> --username <user> --password-stdin`; the password goes through stdin only.
  func login(_ options: LoginOptions, password: String) async throws {
    try await jobs.runAndWait(.login(options), standardInput: Data(password.utf8))
    refresh()
  }

  /// `tart logout <host>`.
  func logout(_ host: String) async throws {
    try await jobs.runAndWait(.logout(host: host))
    refresh()
  }
}
