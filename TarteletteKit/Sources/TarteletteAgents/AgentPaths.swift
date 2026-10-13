import Foundation

/// Where agent settings, the agent VM registry and the agent audit log live.
///
/// The app and every agent helper process resolve the same locations, so the user's settings
/// and the shared registry are seen by all of them.
public struct AgentPaths: Sendable, Hashable {
  /// `~/Library/Application Support/Tartelette` by default.
  public var applicationSupport: URL
  /// `~/Library/Logs/Tartelette` by default.
  public var logs: URL

  public init(applicationSupport: URL, logs: URL) {
    self.applicationSupport = applicationSupport.standardizedFileURL
    self.logs = logs.standardizedFileURL
  }

  /// The user's locations, resolved from the home directory like `TartPaths` (the app isn't sandboxed).
  public static var standard: AgentPaths {
    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    return AgentPaths(
      applicationSupport: library.appendingPathComponent("Application Support/Tartelette", isDirectory: true),
      logs: library.appendingPathComponent("Logs/Tartelette", isDirectory: true))
  }

  /// Per-VM access levels and limits set by the user in the app.
  public var policyFile: URL { applicationSupport.appendingPathComponent("agents.json") }
  /// VMs created by agents, shared by every helper process.
  public var registryFile: URL { applicationSupport.appendingPathComponent("agent-vms.json") }
  /// Held with `flock` around every registry read-modify-write.
  public var registryLockFile: URL { applicationSupport.appendingPathComponent("agent-vms.lock") }
  /// JSON Lines record of every agent tool call.
  public var auditLogFile: URL { logs.appendingPathComponent("agents.log") }
}
