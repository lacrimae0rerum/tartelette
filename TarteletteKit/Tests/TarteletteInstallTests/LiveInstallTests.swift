import Foundation
import Testing

import TarteletteCLI
import TarteletteCore
import TarteletteInstall

/// Downloads about 23 MB from GitHub, so it runs only when asked for:
/// `TARTELETTE_LIVE_INSTALL=1 swift test --filter LiveInstallTests`.
@Suite(
  "Installing the real Tart",
  .enabled(if: ProcessInfo.processInfo.environment["TARTELETTE_LIVE_INSTALL"] == "1", "set TARTELETTE_LIVE_INSTALL=1"))
struct LiveInstallTests {
  @Test func installsTheLatestReleaseAndRunsItThroughTheCurrentLink() async throws {
    let scratch = try ScratchDirectory("live")
    defer { scratch.remove() }
    let layout = ManagedTartLayout(root: scratch.appending("Tart"))
    let release = try await GitHubTartReleaseFeed().latestRelease()

    let state = try await ManagedTartInstaller(layout: layout).install(release)

    #expect(state.current == release.version.description)
    let output = try await ProcessRunner().run(
      ProcessRequest(executable: layout.currentExecutable, arguments: ["--version"], timeout: .seconds(30)))
    print("Installed Tart \(release.version) at \(layout.currentExecutable.path); --version: \(output.stdoutString)")
    #expect(output.succeeded, "\(output.diagnostic)")
    #expect(TartVersion(output.stdoutString) == release.version)
  }
}
