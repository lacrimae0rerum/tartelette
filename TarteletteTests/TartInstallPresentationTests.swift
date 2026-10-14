import Foundation
import Testing
import TarteletteInstall
import TarteletteKit

@testable import Tartelette

/// What Settings › General and the onboarding say and offer about the Tart in use, its updates and
/// the copy Tartelette manages.
@Suite("Tart install presentation")
struct TartSettingsPresentationTests {
  private static let latest = release("2.41.0")

  private func active(_ source: ActiveTart.Source, _ version: String? = "2.40.1", chosen: Bool = false) -> ActiveTart {
    ActiveTart(source: source, version: version.flatMap(TartVersion.init), chosenInSettings: chosen)
  }

  private func presentation(
    _ active: ActiveTart?, _ status: TartUpdateStatus, managed: ManagedTartState = ManagedTartState()
  ) -> TartSettingsPresentation {
    TartSettingsPresentation(active: active, status: status, managed: managed)
  }

  // MARK: Source

  @Test(arguments: [
    (ActiveTart.Source.managed, false, "Managed by Tartelette"),
    (.homebrew, false, "Homebrew"),
    (.other, true, "Chosen in Settings"),
    (.other, false, "Other"),
  ])
  func theSourceSaysWhereTheTartInUseComesFrom(source: ActiveTart.Source, chosen: Bool, text: String) {
    #expect(presentation(active(source, chosen: chosen), .idle).source == text)
  }

  @Test func withoutATartThereIsNoSource() {
    #expect(presentation(nil, .idle).source == nil)
  }

  // MARK: Checking for updates

  @Test(arguments: [ActiveTart.Source.managed, .homebrew, .other])
  func beforeAnyCheckNothingIsSaidOrOffered(source: ActiveTart.Source) {
    let shown = presentation(active(source), .idle)

    #expect(shown.status == nil)
    #expect(!shown.isChecking)
    #expect(shown.installTitle == nil)
    #expect(shown.upgradeCommand == nil)
  }

  @Test func withoutATartInstallingIsOfferedBeforeAnyCheck() {
    #expect(presentation(nil, .idle).installTitle == "Install Tart")
  }

  @Test func aRunningCheckSaysSoAndOffersNothing() {
    let shown = presentation(active(.homebrew), .checking)

    #expect(shown.status == "Checking…")
    #expect(shown.isChecking)
    #expect(shown.installTitle == nil)
    #expect(shown.upgradeCommand == nil)
  }

  @Test(arguments: [ActiveTart.Source.managed, .homebrew, .other])
  func upToDateSaysWhichReleaseIsTheLatest(source: ActiveTart.Source) {
    let shown = presentation(active(source, "2.41.0"), .upToDate(latest: Self.latest))

    #expect(shown.status == "Up to date. Tart 2.41.0 is the latest release.")
    #expect(!shown.statusIsProblem)
    #expect(shown.installTitle == nil)
    #expect(shown.upgradeCommand == nil)
  }

  @Test func aManagedCopyUpdatesWithOneClick() {
    let shown = presentation(
      active(.managed), .updateAvailable(latest: Self.latest, action: .updateManagedCopy),
      managed: ManagedTartState(current: "2.40.1", installed: ["2.40.1"]))

    #expect(shown.status == "Tart 2.41.0 is available.")
    #expect(shown.installTitle == "Update to 2.41.0")
    #expect(shown.upgradeCommand == nil)
  }

  @Test func homebrewsTartShowsTheUpgradeCommandAndOffersTheManagedCopy() {
    let shown = presentation(
      active(.homebrew), .updateAvailable(latest: Self.latest, action: .upgradeWithHomebrew(command: "brew upgrade openai/tools/tart")))

    #expect(shown.status == "Tart 2.41.0 is available.")
    #expect(shown.upgradeCommand == "brew upgrade openai/tools/tart")
    #expect(shown.installTitle == "Install Managed Copy")
    #expect(shown.installNote == "Or let Tartelette keep its own copy, which it updates with one click.")
  }

  @Test func aManagedCopyThatIsAlreadyTheLatestIsOfferedForUse() {
    let managed = ManagedTartState(current: "2.41.0", installed: ["2.41.0"])
    let homebrew = presentation(
      active(.homebrew, chosen: true),
      .updateAvailable(latest: Self.latest, action: .upgradeWithHomebrew(command: "brew upgrade openai/tools/tart")),
      managed: managed)
    let other = presentation(
      active(.other, chosen: true), .updateAvailable(latest: Self.latest, action: .installManagedCopy), managed: managed)

    #expect(homebrew.installTitle == "Use Managed Copy")
    #expect(other.installTitle == "Use Managed Copy")
  }

  @Test func anotherTartOrNoneOffersToInstallTheLatest() {
    let other = presentation(active(.other, nil), .updateAvailable(latest: Self.latest, action: .installManagedCopy))
    let none = presentation(nil, .updateAvailable(latest: Self.latest, action: .installManagedCopy))

    #expect(other.status == "Tart 2.41.0 is available.")
    #expect(other.installTitle == "Install Tart 2.41.0")
    #expect(other.upgradeCommand == nil)
    #expect(none.installTitle == "Install Tart 2.41.0")
  }

  @Test(arguments: [ActiveTart.Source.managed, .homebrew, .other])
  func aFailedCheckShowsWhatToDo(source: ActiveTart.Source) {
    let shown = presentation(active(source), .failed(message: "GitHub can't be reached. Try again later."))

    #expect(shown.status == "GitHub can't be reached. Try again later.")
    #expect(shown.statusIsProblem)
    #expect(shown.installTitle == nil)
  }

  @Test func aFailedCheckWithoutATartStillOffersToInstall() {
    let shown = presentation(nil, .failed(message: "GitHub can't be reached. Try again later."))

    #expect(shown.statusIsProblem)
    #expect(shown.installTitle == "Install Tart")
  }

  // MARK: The managed copy

  @Test func theInstalledVersionsMarkTheOneInUse() {
    let managed = ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"])

    #expect(presentation(active(.managed, "2.41.0"), .idle, managed: managed).managedVersions == "2.41.0 (in use), 2.40.1")
    // A Tart chosen in Settings is in use instead.
    #expect(presentation(active(.homebrew, chosen: true), .idle, managed: managed).managedVersions == "2.41.0, 2.40.1")
  }

  @Test func goingBackIsOfferedOnlyWithAPreviousVersion() {
    let withPrevious = ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"])
    let alone = ManagedTartState(current: "2.41.0", installed: ["2.41.0"])

    #expect(presentation(active(.managed), .idle, managed: withPrevious).rollbackTitle == "Go Back to 2.40.1")
    #expect(presentation(active(.managed), .idle, managed: alone).rollbackTitle == nil)
  }

  @Test func removingIsOfferedOnlyWhenThereIsAManagedCopy() {
    #expect(
      presentation(active(.managed), .idle, managed: ManagedTartState(current: "2.41.0", installed: ["2.41.0"])).canRemove)
    #expect(!presentation(active(.homebrew), .idle).canRemove)
    #expect(presentation(active(.homebrew), .idle).managedVersions == nil)
  }

  // MARK: Using the managed Tart in Terminal

  @Test func theTerminalHintPutsTheManagedTartFirstOnPath() throws {
    let directory = URL(fileURLWithPath: "/Volumes/Data/Library/Application Support/Tartelette/Tart/current/tart.app/Contents/MacOS")

    let hint = TartSettingsPresentation.terminalHint(for: directory)

    #expect(
      hint == #"export PATH="/Volumes/Data/Library/Application Support/Tartelette/Tart/current/tart.app/Contents/MacOS:$PATH""#)
    #expect(try pathAfterRunning(hint) == directory.path + ":/usr/bin:/bin")
  }

  @Test(arguments: [#"/Volumes/A "quoted" $HOME `dir` \ and !bang/MacOS"#, "/Volumes/Tart's Disk/MacOS"])
  func theTerminalHintSurvivesAnyFolderName(_ path: String) throws {
    let hint = TartSettingsPresentation.terminalHint(for: URL(fileURLWithPath: path))

    #expect(try pathAfterRunning(hint) == path + ":/usr/bin:/bin")
  }

  /// Runs `line` in zsh, as if pasted in Terminal, and returns the resulting `PATH`.
  private func pathAfterRunning(_ line: String) throws -> String {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-f", "-c", line + "\n/usr/bin/printenv PATH"]
    shell.environment = ["PATH": "/usr/bin:/bin"]
    let output = Pipe()
    shell.standardOutput = output
    shell.standardError = FileHandle.nullDevice
    try shell.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    shell.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
}

@Suite("Tart install progress")
struct TartOperationProgressTests {
  private let separator = Locale.current.decimalSeparator ?? "."
  private let version = TartVersion("2.41.0")

  private func decimal(_ text: String) -> String {
    text.replacingOccurrences(of: ".", with: separator)
  }

  @Test func lookingForTheReleaseIsIndeterminateAndCancellable() {
    let progress = TartOperationProgress(.installing(version: nil, phase: .findingRelease, fraction: nil), downloaded: nil)

    #expect(progress == TartOperationProgress(text: "Looking for the latest release…", fraction: nil, canCancel: true))
  }

  @Test func downloadingShowsTheVersionAndTheMegabytes() {
    let progress = TartOperationProgress(
      .installing(version: version, phase: .downloading, fraction: 0.4),
      downloaded: TartDownloadAmount(received: 9_240_000, expected: 23_100_000))

    #expect(progress.text == "Downloading Tart 2.41.0… \(decimal("9.2")) of \(decimal("23.1")) MB")
    #expect(progress.fraction == 0.4)
    #expect(progress.canCancel)
  }

  @Test func megabytesKeepOneDecimal() {
    let progress = TartOperationProgress(
      .installing(version: version, phase: .downloading, fraction: 0),
      downloaded: TartDownloadAmount(received: 0, expected: 23_000_000))

    #expect(progress.text == "Downloading Tart 2.41.0… \(decimal("0.0")) of \(decimal("23.0")) MB")
  }

  @Test func aDownloadOfUnknownSizeIsIndeterminate() {
    let known = TartOperationProgress(.installing(version: version, phase: .downloading, fraction: nil), downloaded: nil)
    let unknown = TartOperationProgress(.installing(version: nil, phase: .downloading, fraction: nil), downloaded: nil)

    #expect(known == TartOperationProgress(text: "Downloading Tart 2.41.0…", fraction: nil, canCancel: true))
    #expect(unknown == TartOperationProgress(text: "Downloading Tart…", fraction: nil, canCancel: true))
  }

  @Test func checkingTheSignatureIsIndeterminateAndCancellable() {
    let progress = TartOperationProgress(.installing(version: version, phase: .verifying, fraction: nil), downloaded: nil)

    #expect(progress == TartOperationProgress(text: "Checking the signature…", fraction: nil, canCancel: true))
  }

  @Test func theFinalStepCantBeCancelled() {
    let progress = TartOperationProgress(.installing(version: version, phase: .installing, fraction: nil), downloaded: nil)

    #expect(progress == TartOperationProgress(text: "Installing…", fraction: nil, canCancel: false))
  }

  @Test func goingBackAndRemovingCantBeCancelled() {
    #expect(
      TartOperationProgress(.rollingBack, downloaded: nil)
        == TartOperationProgress(text: "Going back to the previous version…", fraction: nil, canCancel: false))
    #expect(
      TartOperationProgress(.removing, downloaded: nil)
        == TartOperationProgress(text: "Removing the managed copy…", fraction: nil, canCancel: false))
  }
}

@Suite("Tart onboarding")
struct TartOnboardingPresentationTests {
  @Test func theInstallLineSaysWhereTartComesFromAndHowItIsChecked() {
    #expect(
      TartOnboardingPresentation.installSummary
        == "Tartelette downloads the official Tart from GitHub (about 23 MB), checks that it's signed by Tart's developer, and updates it only when you ask."
    )
  }

  @Test func homebrewStaysTheAlternativeWhereItWorks() {
    let alternative = TartOnboardingPresentation.alternative(canUseHomebrew: true)

    #expect(alternative.title == "Prefer Homebrew?")
    #expect(alternative.command == "brew trust --formula openai/tools/tart openai/tools/softnet && brew install openai/tools/tart")
  }

  @Test func onMacOS14TheAlternativeIsTheReleaseDownload() {
    let alternative = TartOnboardingPresentation.alternative(canUseHomebrew: false)

    #expect(alternative.title == "Prefer to install it yourself?")
    #expect(
      alternative.command
        == "curl -fL https://github.com/openai/tart/releases/latest/download/tart.tar.gz | tar -xz -C /Applications")
  }

  @Test func theLicenseLinkPointsAtTartsLicense() {
    #expect(Links.tartLicense.absoluteString == "https://github.com/openai/tart/blob/main/LICENSE")
  }
}

/// A release whose files are never downloaded.
nonisolated private func release(_ version: String) -> TartRelease {
  let base = URL(string: "https://github.com/openai/tart/releases/download/\(version)/")!
  return TartRelease(
    version: TartVersion(version)!, tag: version, publishedAt: nil,
    pageURL: URL(string: "https://github.com/openai/tart/releases/tag/\(version)")!,
    archive: TartReleaseAsset(name: "tart.tar.gz", downloadURL: base.appendingPathComponent("tart.tar.gz"), size: 100),
    checksums: TartReleaseAsset(
      name: "tart_\(version)_checksums.txt", downloadURL: base.appendingPathComponent("tart_\(version)_checksums.txt"),
      size: 80))
}
