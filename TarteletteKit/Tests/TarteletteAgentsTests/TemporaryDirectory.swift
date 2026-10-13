import Foundation

/// A unique scratch directory under the system temporary directory, removed by `remove()`.
struct TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartelette-agents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func file(_ relativePath: String) -> URL { url.appendingPathComponent(relativePath) }

  func remove() { try? FileManager.default.removeItem(at: url) }
}
