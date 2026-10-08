import Foundation

/// Locations inside Tart's home directory (`$TART_HOME`, default `~/.tart`).
public struct TartPaths: Sendable, Hashable {
  public var home: URL

  public init(home: URL) {
    self.home = home.standardizedFileURL
  }

  /// Resolves `TART_HOME` from an environment dictionary, defaulting to `~/.tart`.
  public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> TartPaths {
    if let custom = environment["TART_HOME"], !custom.isEmpty {
      return TartPaths(home: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
    }
    return TartPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart", isDirectory: true))
  }

  public var vms: URL { home.appendingPathComponent("vms", isDirectory: true) }
  public var ociCache: URL { home.appendingPathComponent("cache/OCIs", isDirectory: true) }
  public var ipswCache: URL { home.appendingPathComponent("cache/IPSWs", isDirectory: true) }
  public var temporary: URL { home.appendingPathComponent("tmp", isDirectory: true) }

  public func vmDirectory(_ name: String) -> URL { vms.appendingPathComponent(name, isDirectory: true) }
  public func configFile(_ name: String) -> URL { vmDirectory(name).appendingPathComponent("config.json") }
  public func diskImage(_ name: String) -> URL { vmDirectory(name).appendingPathComponent("disk.img") }
  public func nvram(_ name: String) -> URL { vmDirectory(name).appendingPathComponent("nvram.bin") }
  /// Present while the VM is suspended.
  public func suspendState(_ name: String) -> URL { vmDirectory(name).appendingPathComponent("state.vzvmsave") }
  /// Guest-agent proxy socket, present while the VM runs on a macOS 14+ host.
  public func controlSocket(_ name: String) -> URL { vmDirectory(name).appendingPathComponent("control.sock") }
}

/// Reads the PID of the process holding Tart's VM lock (`fcntl` write lock on `config.json`).
///
/// The holder is normally the `tart run` process (and, briefly, `tart push`). Querying with
/// `F_GETLK` does not disturb the lock.
public enum VMLock {
  public static func holderPID(configFile: URL) -> Int32? {
    let fd = open(configFile.path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var query = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_RDLCK), l_whence: Int16(SEEK_SET))
    guard fcntl(fd, F_GETLK, &query) == 0 else { return nil }
    guard query.l_type != Int16(F_UNLCK), query.l_pid > 0 else { return nil }
    return query.l_pid
  }

  public static func holderPID(vmNamed name: String, paths: TartPaths) -> Int32? {
    holderPID(configFile: paths.configFile(name))
  }
}
