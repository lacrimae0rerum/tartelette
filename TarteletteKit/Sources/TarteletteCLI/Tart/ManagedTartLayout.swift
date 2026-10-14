import Foundation

/// Where Tartelette keeps the copy of Tart it downloads and manages.
///
/// ```
/// <root>/versions/<version>/tart.app   one directory per installed version
/// <root>/current -> versions/<version> relative link selecting the active version
/// <root>/staging/                      scratch space for downloads and extraction
/// <root>/manifest.json                 the version to go back to
/// <root>/.lock                         held by the installer while it changes the layout
/// ```
///
/// Versions live side by side and the `current` link is switched atomically, so new commands use the
/// new version while running VMs keep the binary they started with. This type only reads the
/// layout; the installer writes it.
public struct ManagedTartLayout: Sendable, Hashable {
  /// `~/Library/Application Support/Tartelette/Tart` by default.
  public var root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  /// The user's location, resolved from the home directory like `AgentPaths` (the app isn't sandboxed).
  public static var standard: ManagedTartLayout {
    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    return ManagedTartLayout(
      root: library.appendingPathComponent("Application Support/Tartelette/Tart", isDirectory: true))
  }

  /// The directory holding one subdirectory per installed version.
  public var versionsDirectory: URL { root.appendingPathComponent("versions", isDirectory: true) }

  /// The directory of one installed version, holding its `tart.app`.
  public func versionDirectory(_ version: String) -> URL {
    versionsDirectory.appendingPathComponent(version, isDirectory: true)
  }

  /// The relative symbolic link to the active version's directory.
  public var currentLink: URL { root.appendingPathComponent("current") }

  /// Scratch space for downloads and extraction, on the same volume as `versionsDirectory`.
  public var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

  /// The installer's record of the version that was active before the current one.
  public var manifestFile: URL { root.appendingPathComponent("manifest.json") }

  /// The file the installer locks so only one process changes the layout at a time.
  public var lockFile: URL { root.appendingPathComponent(".lock") }

  /// The active version's `tart` executable, reached through the `current` link.
  public var currentExecutable: URL { currentLink.appendingPathComponent("tart.app/Contents/MacOS/tart") }

  /// The active version: the last path component of the `current` link's destination.
  ///
  /// nil when the link is missing or dangling.
  public var currentVersion: String? {
    let fileManager = FileManager.default
    // `fileExists` follows the link, so it is false for a dangling one.
    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: currentLink.path),
      fileManager.fileExists(atPath: currentLink.path)
    else { return nil }
    return (destination as NSString).lastPathComponent
  }
}
