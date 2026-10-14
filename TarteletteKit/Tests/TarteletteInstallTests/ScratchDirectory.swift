import Foundation

/// A temporary directory removed by `remove()`.
struct ScratchDirectory {
  let url: URL

  init(_ label: String = "install") throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartelette-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func appending(_ path: String) -> URL { url.appendingPathComponent(path) }

  func remove() {
    // Undo any permissions a test removed so cleanup succeeds.
    if let items = FileManager.default.enumerator(atPath: url.path) {
      for case let item as String in items {
        let path = url.appendingPathComponent(item).path
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
      }
    }
    try? FileManager.default.removeItem(at: url)
  }
}
