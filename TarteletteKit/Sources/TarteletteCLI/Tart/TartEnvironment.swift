import Foundation
import TarteletteCore

/// Where the `tart` executable lives and the environment every invocation receives.
public struct TartEnvironment: Sendable, Hashable {
  /// The `tart` executable (often Homebrew's wrapper script around `tart.app`).
  public var executable: URL
  /// Tart's home directory layout (`TART_HOME`).
  public var paths: TartPaths
  /// Additional variables such as `TART_NO_AUTO_PRUNE` or `TART_REGISTRY_USERNAME`.
  public var extraVariables: [String: String]
  /// Where `executable` comes from.
  public var source: Source
  /// Whether `executable` is the path the user chose in Settings rather than one found automatically.
  public var usesPreferredExecutable: Bool

  public init(
    executable: URL,
    paths: TartPaths = .resolve(),
    extraVariables: [String: String] = [:],
    source: Source = .other,
    usesPreferredExecutable: Bool = false
  ) {
    self.executable = executable
    self.paths = paths
    self.extraVariables = extraVariables
    self.source = source
    self.usesPreferredExecutable = usesPreferredExecutable
  }

  /// Directories searched for `tart`, `softnet` and `docker-credential-*` helpers. Apps launched
  /// from Finder inherit a minimal PATH that lacks Homebrew.
  public static let standardSearchDirectories = [
    "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
  ]

  /// Well-known install locations of the `tart` executable, in lookup order.
  public static var executableCandidates: [String] {
    [
      "/opt/homebrew/bin/tart",
      "/usr/local/bin/tart",
      "/Applications/tart.app/Contents/MacOS/tart",
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tart").path,
    ]
  }

  /// Finds an installed `tart`.
  ///
  /// Lookup order: the preferred path, the copy Tartelette manages, the well-known install
  /// locations, then `$PATH`. The first executable wins; a preferred path that isn't executable
  /// falls through to the others.
  ///
  /// - Parameters:
  ///   - preferredExecutablePath: A user-chosen path, tried first (`~` is expanded).
  ///   - tartHome: A custom `TART_HOME`; defaults to `$TART_HOME` or `~/.tart`.
  ///   - managedLayout: Where Tartelette keeps the Tart it manages.
  /// - Returns: nil when no executable could be found.
  public static func detect(
    preferredExecutablePath: String? = nil,
    tartHome: String? = nil,
    managedLayout: ManagedTartLayout = .standard
  ) -> TartEnvironment? {
    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return detect(
      preferredExecutablePath: preferredExecutablePath,
      tartHome: tartHome,
      managedLayout: managedLayout,
      otherCandidates: executableCandidates + inheritedPath.split(separator: ":").map { "\($0)/tart" })
  }

  /// `detect` with the candidates after the managed copy given explicitly, so tests don't depend on
  /// the Tart installed on the machine running them.
  static func detect(
    preferredExecutablePath: String?,
    tartHome: String?,
    managedLayout: ManagedTartLayout,
    otherCandidates: [String]
  ) -> TartEnvironment? {
    let paths: TartPaths =
      if let tartHome, !tartHome.isEmpty {
        TartPaths(home: URL(fileURLWithPath: (tartHome as NSString).expandingTildeInPath, isDirectory: true))
      } else {
        TartPaths.resolve()
      }

    let preferred = preferredExecutablePath.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
    // A missing or dangling `current` link isn't executable, so it is skipped like any other candidate.
    let candidates = [preferred].compactMap { $0 } + [managedLayout.currentExecutable.path] + otherCandidates

    let fileManager = FileManager.default
    guard let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else { return nil }
    let executable = URL(fileURLWithPath: found)
    return TartEnvironment(
      executable: executable,
      paths: paths,
      source: .classify(
        executable: executable, resolvedExecutable: executable.resolvingSymlinksInPath(), managedLayout: managedLayout),
      usesPreferredExecutable: found == preferred)
  }

  /// A PATH that keeps the inherited entries and appends Homebrew and system directories, plus
  /// the directory containing `tart` itself (where Homebrew's `softnet` is installed too; a managed
  /// Tart has none next to it and relies on the Homebrew directories).
  public var searchPath: String {
    searchPath(inheriting: ProcessInfo.processInfo.environment["PATH"] ?? "")
  }

  /// `searchPath` for a given inherited PATH, such as the minimal one of an app launched from Finder.
  func searchPath(inheriting inheritedPath: String) -> String {
    let inherited = inheritedPath.split(separator: ":").map(String.init)
    var seen = Set<String>()
    var directories: [String] = []
    for directory in inherited + [executable.deletingLastPathComponent().path] + Self.standardSearchDirectories
    where !directory.isEmpty && seen.insert(directory).inserted {
      directories.append(directory)
    }
    return directories.joined(separator: ":")
  }

  /// Where a `tart` executable comes from.
  public enum Source: Sendable, Hashable {
    /// The copy Tartelette downloaded and manages, with its version when the layout shows it.
    case managed(version: String?)
    /// Homebrew's `tart` formula.
    case homebrew
    /// Anything else: `/Applications/tart.app`, a manual install, a build somewhere in `$PATH`.
    case other

    /// Path prefixes of Homebrew installs: Apple silicon's prefix, and the Intel prefix's Cellar
    /// (`/usr/local/bin` also holds tools Homebrew doesn't manage).
    static let homebrewPrefixes = ["/opt/homebrew/", "/usr/local/Cellar/"]

    /// Classifies an executable from its path and its symlink-resolved path, without touching the disk.
    ///
    /// Homebrew's `/opt/homebrew/bin/tart` is a link into `Cellar/tart/<version>/bin`, and the managed
    /// `current/tart.app/…` resolves into `versions/<version>/tart.app/…`, which names the version.
    static func classify(executable: URL, resolvedExecutable: URL, managedLayout: ManagedTartLayout) -> Source {
      let resolved = resolvedExecutable.standardizedFileURL
      let managedPrefix = managedLayout.root.path + "/"
      if [executable.standardizedFileURL, resolved].contains(where: { $0.path.hasPrefix(managedPrefix) }) {
        return .managed(version: managedVersion(of: resolved))
      }
      if homebrewPrefixes.contains(where: { resolved.path.hasPrefix($0) }) { return .homebrew }
      return .other
    }

    /// The `<version>` of a resolved `…/versions/<version>/tart.app/Contents/MacOS/tart`.
    private static func managedVersion(of resolvedExecutable: URL) -> String? {
      let components = resolvedExecutable.pathComponents
      guard components.count >= 6, components.suffix(4).elementsEqual(["tart.app", "Contents", "MacOS", "tart"]),
        components[components.count - 6] == "versions"
      else { return nil }
      return components[components.count - 5]
    }
  }

  /// Whether `paths` differs from Tart's default `~/.tart`.
  public var usesCustomHome: Bool {
    paths.home != TartPaths.resolve(environment: [:]).home
  }

  /// Variables to set for a `tart` invocation (merged over the app's own environment).
  ///
  /// Every command except `run` gets `CI=1`, which makes Tart print plain `N%` progress lines
  /// instead of ANSI cursor redraws. `run` is left interactive so `--vnc` opens Screen Sharing.
  public func variables(forRun: Bool) -> [String: String] {
    var variables: [String: String] = ["PATH": searchPath]
    if usesCustomHome || ProcessInfo.processInfo.environment["TART_HOME"] != nil {
      variables["TART_HOME"] = paths.home.path
    }
    if !forRun { variables["CI"] = "1" }
    variables.merge(extraVariables) { _, extra in extra }
    return variables
  }
}
