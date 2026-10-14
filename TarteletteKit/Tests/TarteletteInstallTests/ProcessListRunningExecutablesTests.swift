import Foundation
import Testing

@testable import TarteletteInstall

@Suite("Running executables")
struct ProcessListRunningExecutablesTests {
  /// Starts a copy of `/bin/sleep` saved at `path`, ad-hoc signed so it runs from there, launched
  /// through `launchPath` (such as a path through the `current` link) when given.
  func startSleeper(at path: URL, launchingThrough launchPath: URL? = nil) throws -> Process {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path.path)
    let codesign = Process()
    codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    codesign.arguments = ["--force", "--sign", "-", path.path]
    codesign.standardError = FileHandle.nullDevice
    try codesign.run()
    codesign.waitUntilExit()
    try #require(codesign.terminationStatus == 0)

    let sleeper = Process()
    sleeper.executableURL = launchPath ?? path
    sleeper.arguments = ["30"]
    try sleeper.run()
    return sleeper
  }

  /// Polls until `provider` lists `path`, for up to five seconds.
  func waitUntilListed(_ path: String, by provider: some RunningExecutablesProviding) async throws -> Bool {
    for _ in 0..<50 {
      if try provider.runningExecutablePaths().contains(path) { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  @Test func listsTheResolvedExecutableOfARunningProcess() async throws {
    let scratch = try ScratchDirectory("running")
    defer { scratch.remove() }
    let sleeper = try startSleeper(at: scratch.appending("bin/tart"))
    defer { sleeper.terminate() }

    let resolved = try #require(realpath(scratch.appending("bin/tart").path, nil))
    defer { free(resolved) }
    #expect(try await waitUntilListed(String(cString: resolved), by: ProcessListRunningExecutables()))
  }

  @Test func theInstallerWontRemoveAVersionARealProcessRuns() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.40.0"))
    let executable = fixture.managed("versions/2.40.0/tart.app/Contents/MacOS/tart")
    let sleeper = try startSleeper(at: executable)
    defer { sleeper.terminate() }
    let provider = ProcessListRunningExecutables()
    let resolved = fixture.realPath("versions/2.40.0/tart.app/Contents/MacOS/tart")
    try #require(try await waitUntilListed(resolved, by: provider))

    let installer = ManagedTartInstaller(
      layout: fixture.layout, downloader: fixture.downloader, verifier: fixture.verifier,
      runningExecutables: provider)
    await #expect(throws: TartInstallError.inUse(versions: ["2.40.0"])) { try await installer.remove() }
    #expect(FileManager.default.fileExists(atPath: executable.path))
  }

  @Test func aProcessStartedThroughCurrentKeepsItsVersionThroughUpdatesAndBlocksRemove() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let provider = ProcessListRunningExecutables()
    let installer = ManagedTartInstaller(
      layout: fixture.layout, downloader: fixture.downloader, verifier: fixture.verifier,
      runningExecutables: provider)
    try await installer.install(try fixture.publish("2.40.0"))
    // Started through `current`, like `tart run`; the kernel reports the resolved versions/2.40.0 path.
    let sleeper = try startSleeper(
      at: fixture.managed("versions/2.40.0/tart.app/Contents/MacOS/tart"),
      launchingThrough: fixture.managed("current/tart.app/Contents/MacOS/tart"))
    defer { sleeper.terminate() }
    let resolved = fixture.realPath("versions/2.40.0/tart.app/Contents/MacOS/tart")
    try #require(try await waitUntilListed(resolved, by: provider))

    try await installer.install(try fixture.publish("2.41.0"))
    try await installer.install(try fixture.publish("2.42.0"))
    #expect(try await installer.prune() == [])

    #expect(
      installer.state()
        == ManagedTartState(current: "2.42.0", previous: "2.41.0", installed: ["2.40.0", "2.41.0", "2.42.0"]))
    await #expect(throws: TartInstallError.inUse(versions: ["2.40.0"])) { try await installer.remove() }
    #expect(sleeper.isRunning)
    #expect(FileManager.default.fileExists(atPath: resolved))
  }
}
