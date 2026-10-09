import Foundation
import Testing
import TarteletteKit

@testable import Tartelette

/// An in-memory `SecretStore`, so tests never touch the login Keychain.
nonisolated final class MemorySecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]

  init(_ values: [String: String] = [:]) { self.values = values }

  func read(service: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[service]
  }

  func write(_ value: String?, service: String) {
    lock.lock()
    defer { lock.unlock() }
    values[service] = (value?.isEmpty ?? true) ? nil : value
  }
}

@Suite("Settings and run profiles")
struct SettingsAndProfilesTests {
  private func defaults() -> UserDefaults {
    let suite = "tartelette-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  // MARK: AppSettings

  @Test func defaultsMatchTheDocumentedValues() {
    let settings = AppSettings(defaults: defaults(), secrets: MemorySecretStore())
    #expect(settings.tartExecutablePath == nil)
    #expect(settings.tartHome == nil)
    #expect(settings.refreshInterval == 3)
    #expect(settings.metricsInterval == 1)
    #expect(settings.historyMinutes == 15)
    #expect(settings.showMenuBarExtra)
    #expect(!settings.stopVMsOnQuit)
    #expect(settings.defaultClipboardEngine == .automatic)
    #expect(settings.liveSyncByDefault)
    #expect(settings.maxAutoTransferMB == 50)
    #expect(settings.sshUsername == CatalogImage.defaultUsername)
    #expect(settings.effectiveSSHPassword == CatalogImage.defaultPassword)
    #expect(settings.tartVariables.isEmpty)
  }

  @Test func settingsPersistAcrossInstances() {
    let defaults = defaults()
    let secrets = MemorySecretStore()
    let first = AppSettings(defaults: defaults, secrets: secrets)
    first.refreshInterval = 7
    first.defaultClipboardEngine = .spice
    first.tartHome = "/tmp/tart-home"
    first.sshPassword = "s3cret"

    let second = AppSettings(defaults: defaults, secrets: secrets)
    #expect(second.refreshInterval == 7)
    #expect(second.defaultClipboardEngine == .spice)
    #expect(second.tartHome == "/tmp/tart-home")
    #expect(second.sshPassword == "s3cret")
    #expect(secrets.read(service: AppSettings.sshService) == "s3cret")

    first.tartHome = nil
    #expect(AppSettings(defaults: defaults, secrets: secrets).tartHome == nil)
  }

  @Test func tartVariablesNeedACompleteCredentialPair() {
    let settings = AppSettings(defaults: defaults(), secrets: MemorySecretStore())
    settings.disableAutoPrune = true
    #expect(settings.tartVariables == ["TART_NO_AUTO_PRUNE": "1"])

    settings.registryUsername = "octocat"
    #expect(settings.tartVariables["TART_REGISTRY_USERNAME"] == nil)  // no password yet

    settings.registryPassword = "token"
    settings.registryHostname = "ghcr.io"
    #expect(
      settings.tartVariables == [
        "TART_NO_AUTO_PRUNE": "1",
        "TART_REGISTRY_USERNAME": "octocat",
        "TART_REGISTRY_PASSWORD": "token",
        "TART_REGISTRY_HOSTNAME": "ghcr.io",
      ])
  }

  // MARK: Registry override draft

  @Test func registryDraftOnlyAcceptsConsistentSets() {
    #expect(RegistryOverrideDraft().isConsistent)  // clearing everything is fine
    #expect(RegistryOverrideDraft(username: "me", password: "", hostname: "").problem != nil)
    #expect(RegistryOverrideDraft(username: "", password: "pw", hostname: "").problem != nil)
    #expect(RegistryOverrideDraft(username: "", password: "", hostname: "ghcr.io").problem != nil)
    #expect(RegistryOverrideDraft(username: "me", password: "pw", hostname: "https://ghcr.io").problem != nil)
    #expect(RegistryOverrideDraft(username: "me", password: "pw", hostname: "ghcr.io").isConsistent)
    #expect(RegistryOverrideDraft(username: " me ", password: "pw", hostname: " localhost:5000 ").isConsistent)
  }

  @Test func registryDraftComparesNormalizedValues() {
    let draft = RegistryOverrideDraft(username: " me ", password: "pw", hostname: " ghcr.io ")
    #expect(draft.normalized == RegistryOverrideDraft(username: "me", password: "pw", hostname: "ghcr.io"))
    #expect(!draft.differs(username: "me", password: "pw", hostname: "ghcr.io"))
    #expect(draft.differs(username: "me", password: "other", hostname: "ghcr.io"))
  }

  // MARK: RunProfileStore

  @Test func profilesPersistRenameAndRemove() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartelette-profiles-\(UUID())", isDirectory: true)
      .appendingPathComponent("profiles.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let store = RunProfileStore(fileURL: file, defaultEngine: { .bridge })
    #expect(store.profile(for: "dev") == RunProfile(options: RunOptions(name: "dev"), clipboardEngine: .bridge))
    #expect(!store.hasCustomProfile("dev"))

    store.update("dev") { profile in
      profile.options.display = .headless
      profile.clipboardEngine = .off
      profile.stopTimeout = 5
    }
    let reloaded = RunProfileStore(fileURL: file, defaultEngine: { .bridge })
    #expect(reloaded.hasCustomProfile("dev"))
    #expect(reloaded.profile(for: "dev").options.display == .headless)
    #expect(reloaded.profile(for: "dev").clipboardEngine == .off)

    reloaded.rename(from: "dev", to: "prod")
    #expect(!reloaded.hasCustomProfile("dev"))
    #expect(reloaded.profile(for: "prod").options.name == "prod")
    #expect(reloaded.profile(for: "prod").stopTimeout == 5)
    #expect(RunProfileStore(fileURL: file, defaultEngine: { .bridge }).hasCustomProfile("prod"))

    reloaded.remove("prod")
    #expect(!RunProfileStore(fileURL: file, defaultEngine: { .bridge }).hasCustomProfile("prod"))
  }

  @Test func corruptProfileFileFallsBackToDefaults() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-profiles-\(UUID()).json")
    try Data("not json".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = RunProfileStore(fileURL: file, defaultEngine: { .automatic })
    #expect(store.profiles.isEmpty)
    #expect(store.profile(for: "vm").options == RunOptions(name: "vm"))
  }

  // MARK: KeyValueGrid

  @Test func keyValueRowsGetStableUniqueIdentities() {
    let rows = [KeyValueRow("State", "Running"), KeyValueRow("Disk", "a"), KeyValueRow("Disk", "b")]
    #expect(KeyValueGrid.identities(for: rows) == ["State", "Disk", "Disk#2"])
    #expect(KeyValueGrid.identities(for: rows) == KeyValueGrid.identities(for: rows))
  }
}
