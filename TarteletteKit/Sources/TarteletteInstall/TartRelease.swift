import Foundation

/// A published Tart release and the two files the installer downloads from it.
public struct TartRelease: Sendable, Equatable {
  public var version: TartVersion
  /// The release's Git tag as GitHub reports it, such as `2.41.0`.
  public var tag: String
  /// When the release was published, if GitHub says.
  public var publishedAt: Date?
  /// The release's page on GitHub, with its notes.
  public var pageURL: URL
  /// `tart.tar.gz`: `tart.app` and its LICENSE.
  public var archive: TartReleaseAsset
  /// `tart_<version>_checksums.txt`: the SHA-256 of the archive.
  public var checksums: TartReleaseAsset

  public init(
    version: TartVersion, tag: String, publishedAt: Date?, pageURL: URL, archive: TartReleaseAsset,
    checksums: TartReleaseAsset
  ) {
    self.version = version
    self.tag = tag
    self.publishedAt = publishedAt
    self.pageURL = pageURL
    self.archive = archive
    self.checksums = checksums
  }

  /// The name of the archive asset in every release.
  static let archiveName = "tart.tar.gz"

  /// The name of the checksums asset of the release tagged `tag`: `tart_2.41.0_checksums.txt`.
  static func checksumsName(forTag tag: String) -> String {
    "tart_\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)_checksums.txt"
  }
}

/// A file attached to a release.
public struct TartReleaseAsset: Sendable, Equatable {
  public var name: String
  public var downloadURL: URL
  /// Size in bytes.
  public var size: Int64

  public init(name: String, downloadURL: URL, size: Int64) {
    self.name = name
    self.downloadURL = downloadURL
    self.size = size
  }
}
