import Foundation
import TarteletteInstall
import TarteletteKit

/// What Settings › General says about the Tart in use, the last "Check for Updates" and the copy
/// Tartelette manages, and which buttons it offers. Pure: views only lay it out.
nonisolated struct TartSettingsPresentation: Equatable {
  /// Where the Tart in use comes from; nil when there's no Tart.
  var source: String?
  /// What the last check found; nil before any check.
  var status: String?
  /// Whether `status` is a failure to show as one.
  var statusIsProblem = false
  var isChecking = false
  /// The button that installs or updates the managed copy (`installLatest()`); nil when there's
  /// nothing to install.
  var installTitle: String?
  /// A word about `installTitle` when it isn't the obvious next step.
  var installNote: String?
  /// The Homebrew command that updates the Tart in use.
  var upgradeCommand: String?
  /// The managed copy's versions, newest first, the one in use marked; nil when there's no copy.
  var managedVersions: String?
  /// "Go Back to 2.40.1"; nil without a previous version.
  var rollbackTitle: String?
  var canRemove = false

  init(active: ActiveTart?, status: TartUpdateStatus, managed: ManagedTartState) {
    source = active.map(Self.sourceText)

    switch status {
    case .idle:
      break
    case .checking:
      self.status = "Checking…"
      isChecking = true
    case .upToDate(let latest):
      self.status = "Up to date. Tart \(latest.version) is the latest release."
    case .updateAvailable(let latest, let action):
      self.status = "Tart \(latest.version) is available."
      // Installing a version the managed copy already has only switches to it.
      let managedIsLatest = managed.current.flatMap(TartVersion.init) == latest.version
      switch action {
      case .updateManagedCopy:
        installTitle = "Update to \(latest.version)"
      case .upgradeWithHomebrew(let command):
        upgradeCommand = command
        installTitle = managedIsLatest ? "Use Managed Copy" : "Install Managed Copy"
        installNote = "Or let Tartelette keep its own copy, which it updates with one click."
      case .installManagedCopy:
        installTitle = managedIsLatest ? "Use Managed Copy" : "Install Tart \(latest.version)"
      }
    case .failed(let message):
      self.status = message
      statusIsProblem = true
    }
    // Without any Tart, installing is always the way forward: it looks up the latest release itself.
    if active == nil, installTitle == nil, !isChecking { installTitle = "Install Tart" }

    let hasManagedCopy = managed.current != nil || !managed.installed.isEmpty
    if hasManagedCopy {
      let inUse = active?.source == .managed ? managed.current : nil
      managedVersions = managed.installed.reversed()
        .map { $0 == inUse ? "\($0) (in use)" : $0 }
        .joined(separator: ", ")
    }
    rollbackTitle = managed.previous.map { "Go Back to \($0)" }
    canRemove = hasManagedCopy
  }

  private static func sourceText(_ active: ActiveTart) -> String {
    switch active.source {
    case .managed: "Managed by Tartelette"
    case .homebrew: "Homebrew"
    case .other: active.chosenInSettings ? "Chosen in Settings" : "Other"
    }
  }

  /// The line that puts the Tart in `directory` first on `PATH` in the user's own shell.
  ///
  /// `export PATH="<directory>:$PATH"` when nothing in the folder name needs escaping inside double
  /// quotes (spaces don't); otherwise the folder in single quotes, which a shell never expands.
  static func terminalHint(for directory: URL) -> String {
    let path = directory.path
    if path.contains(where: { "\"$`\\!".contains($0) }) {
      return "export PATH=\(ShellQuoting.quote(path)):\"$PATH\""
    }
    return "export PATH=\"\(path):$PATH\""
  }

  /// Tartelette's promise about the network, under the Tart settings.
  static let networkNote = "Tartelette connects to GitHub only when you press Check for Updates, Install or Update."
}

/// The running install, rollback or removal as a sentence, a progress bar and whether it can be
/// cancelled.
nonisolated struct TartOperationProgress: Equatable {
  var text: String
  /// 0…1, or nil for an indeterminate bar.
  var fraction: Double?
  var canCancel: Bool

  init(text: String, fraction: Double?, canCancel: Bool) {
    self.text = text
    self.fraction = fraction
    self.canCancel = canCancel
  }

  /// - Parameter downloaded: How much of the archive arrived, while it downloads.
  init(_ operation: TartInstallationOperation, downloaded: TartDownloadAmount?) {
    switch operation {
    case .installing(let version, let phase, let fraction):
      switch phase {
      case .findingRelease:
        self.init(text: "Looking for the latest release…", fraction: nil, canCancel: true)
      case .downloading:
        var text = version.map { "Downloading Tart \($0)…" } ?? "Downloading Tart…"
        if let downloaded {
          text += " \(Self.megabytes(downloaded.received)) of \(Self.megabytes(downloaded.expected)) MB"
        }
        self.init(text: text, fraction: fraction, canCancel: true)
      case .verifying:
        self.init(text: "Checking the signature…", fraction: nil, canCancel: true)
      case .installing:
        // Moving the verified version into place takes a moment and isn't interrupted.
        self.init(text: "Installing…", fraction: nil, canCancel: false)
      }
    case .rollingBack:
      self.init(text: "Going back to the previous version…", fraction: nil, canCancel: false)
    case .removing:
      self.init(text: "Removing the managed copy…", fraction: nil, canCancel: false)
    }
  }

  /// Decimal megabytes, like Finder, always with one decimal so the numbers don't jump as they grow.
  private static func megabytes(_ bytes: Int64) -> String {
    (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)).grouping(.never))
  }
}

/// What the "Tart Isn't Installed" screen says.
nonisolated enum TartOnboardingPresentation {
  /// Another way to install Tart, in Terminal.
  struct Alternative: Equatable {
    var title: String
    var message: String
    var command: String
  }

  static let installSummary =
    "Tartelette downloads the official Tart from GitHub (about 23 MB), checks that it's signed by Tart's developer, and updates it only when you ask."

  /// Homebrew where its Tart runs (macOS 15 and later), the release download elsewhere.
  static func alternative(canUseHomebrew: Bool) -> Alternative {
    canUseHomebrew
      ? Alternative(
        title: "Prefer Homebrew?", message: "Install Tart with Homebrew in Terminal, then check again.",
        command: Links.homebrewInstallCommand)
      : Alternative(
        title: "Prefer to install it yourself?",
        message: "Unpack the release download into Applications in Terminal, then check again.",
        command: Links.archiveInstallCommand)
  }
}
