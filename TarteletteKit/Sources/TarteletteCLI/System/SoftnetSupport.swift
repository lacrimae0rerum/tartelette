import Foundation
import TarteletteCore

/// Helpers for Softnet, Tart's userspace-filtered network (`tart run --net-softnet`).
///
/// Softnet must be setuid-root. Tart only offers to fix that with `sudo` when attached to a
/// terminal, so a GUI has to do it itself with an administrator prompt.
public enum SoftnetSupport {
  /// Finds the `softnet` executable in `searchPath` (a `PATH`-style list of directories).
  public static func locate(searchPath: String) -> URL? {
    searchPath.split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appendingPathComponent("softnet") }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// Finds `softnet` using the PATH Tart itself will be launched with.
  public static func locate(environment: TartEnvironment) -> URL? {
    locate(searchPath: environment.searchPath)
  }

  /// Whether the executable (after resolving symlinks) is owned by root with the setuid bit set.
  public static func isPrivileged(_ url: URL) -> Bool {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return false }
    return info.st_uid == 0 && (info.st_mode & S_ISUID) != 0
  }

  /// Makes Softnet setuid-root after the user authenticates in the standard administrator dialog.
  ///
  /// - Throws: `ProcessRunError.cancelled` when the user dismisses the dialog, or
  ///   `ProcessRunError.failed` with the reason otherwise.
  public static func enablePrivileges(for url: URL, runner: any ProcessRunning) async throws {
    let output = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/osascript"),
        arguments: ["-e", privilegeScript(for: url)],
        timeout: .seconds(300)
      ))
    guard output.succeeded else {
      let message = output.diagnostic
      if message.contains("-128") { throw ProcessRunError.cancelled }
      throw ProcessRunError.failed(status: output.status, message: message)
    }
  }

  /// The AppleScript that runs `chown root … && chmod u+s …` with administrator privileges.
  static func privilegeScript(for url: URL) -> String {
    let path = url.resolvingSymlinksInPath().path
    let shell = "chown root \(ShellQuoting.quote(path)) && chmod u+s \(ShellQuoting.quote(path))"
    let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(literal)\" with administrator privileges"
  }
}
