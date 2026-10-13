import Foundation
import TarteletteCore

/// Identifies one instance of a VM directory.
///
/// Built from the directory's device, inode and birth time, so a VM deleted and recreated under
/// the same name gets a different fingerprint, while renaming files inside it doesn't change it.
public enum VMFingerprint {
  /// The fingerprint of a directory, or nil when it doesn't exist or isn't a directory.
  public static func of(directory: URL) -> String? {
    var info = stat()
    guard stat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    let birth = info.st_birthtimespec
    return "\(info.st_dev):\(info.st_ino):\(birth.tv_sec).\(birth.tv_nsec)"
  }

  /// The fingerprint of a local VM's directory (`$TART_HOME/vms/<name>`).
  public static func of(vmNamed name: String, paths: TartPaths) -> String? {
    of(directory: paths.vmDirectory(name))
  }
}
