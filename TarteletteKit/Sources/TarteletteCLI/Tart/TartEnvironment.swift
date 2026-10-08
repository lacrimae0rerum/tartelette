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

  public init(executable: URL, paths: TartPaths = .resolve(), extraVariables: [String: String] = [:]) {
    self.executable = executable
    self.paths = paths
    self.extraVariables = extraVariables
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
  /// - Parameters:
  ///   - preferredExecutablePath: A user-chosen path, tried first (`~` is expanded).
  ///   - tartHome: A custom `TART_HOME`; defaults to `$TART_HOME` or `~/.tart`.
  /// - Returns: nil when no executable could be found.
  public static func detect(preferredExecutablePath: String? = nil, tartHome: String? = nil) -> TartEnvironment? {
    let paths: TartPaths =
      if let tartHome, !tartHome.isEmpty {
        TartPaths(home: URL(fileURLWithPath: (tartHome as NSString).expandingTildeInPath, isDirectory: true))
      } else {
        TartPaths.resolve()
      }

    var candidates: [String] = []
    if let preferredExecutablePath, !preferredExecutablePath.isEmpty {
      candidates.append((preferredExecutablePath as NSString).expandingTildeInPath)
    }
    candidates += executableCandidates
    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    candidates += inheritedPath.split(separator: ":").map { "\($0)/tart" }

    let fileManager = FileManager.default
    guard let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else { return nil }
    return TartEnvironment(executable: URL(fileURLWithPath: found), paths: paths)
  }

  /// A PATH that keeps the inherited entries and appends Homebrew and system directories, plus
  /// the directory containing `tart` itself (where `softnet` is usually installed too).
  public var searchPath: String {
    let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    var seen = Set<String>()
    var directories: [String] = []
    for directory in inherited + [executable.deletingLastPathComponent().path] + Self.standardSearchDirectories
    where !directory.isEmpty && seen.insert(directory).inserted {
      directories.append(directory)
    }
    return directories.joined(separator: ":")
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
