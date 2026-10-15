import Foundation

/// Where Tartelette learns about Tart releases.
public protocol TartReleaseFeed: Sendable {
  /// The newest published Tart release. Throws `TartReleaseError`, or `CancellationError` when the
  /// task is cancelled.
  func latestRelease() async throws -> TartRelease
}

/// The latest release of `openai/tart`, from GitHub's REST API.
///
/// It connects only when `latestRelease()` is called.
public struct GitHubTartReleaseFeed: TartReleaseFeed {
  public static let latestReleaseURL = URL(string: "https://api.github.com/repos/openai/tart/releases/latest")!

  private let client: any HTTPClient
  private let userAgent: String

  /// - Parameter userAgent: GitHub requires one; it should name Tartelette, like `Tartelette/1.1.0`.
  public init(client: any HTTPClient = URLSession.shared, userAgent: String = "Tartelette") {
    self.client = client
    self.userAgent = userAgent
  }

  public func latestRelease() async throws -> TartRelease {
    var request = URLRequest(url: Self.latestReleaseURL)
    request.httpMethod = "GET"
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await client.httpData(for: request)
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch {
      throw TartReleaseError.network(reason: error.localizedDescription)
    }
    if let failure = Self.failure(for: response) { throw failure }
    return try Self.release(from: data)
  }

  /// The error an unsuccessful response stands for, or nil for a 2xx.
  private static func failure(for response: HTTPURLResponse) -> TartReleaseError? {
    switch response.statusCode {
    case 200..<300:
      return nil
    case let status
    where [403, 429].contains(status) && response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
      let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
      return .rateLimited(resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
    case 404:
      return .noRelease
    default:
      return .httpStatus(response.statusCode)
    }
  }

  private static func release(from data: Data) throws -> TartRelease {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let payload = try? decoder.decode(GitHubRelease.self, from: data) else {
      throw TartReleaseError.unexpectedResponse(reason: "The answer isn't a GitHub release description.")
    }
    if payload.draft { throw TartReleaseError.notUsable(tag: payload.tagName, reason: .draft) }
    if payload.prerelease { throw TartReleaseError.notUsable(tag: payload.tagName, reason: .prerelease) }
    guard let version = TartVersion(payload.tagName) else {
      throw TartReleaseError.unexpectedResponse(
        reason: "The release tag “\(payload.tagName)” isn't a version number.")
    }

    func asset(named name: String) throws -> TartReleaseAsset {
      guard let asset = payload.assets.first(where: { $0.name == name }) else {
        throw TartReleaseError.missingAsset(name: name, tag: payload.tagName)
      }
      return TartReleaseAsset(name: asset.name, downloadURL: asset.browserDownloadURL, size: asset.size)
    }

    return TartRelease(
      version: version, tag: payload.tagName, publishedAt: payload.publishedAt, pageURL: payload.htmlURL,
      archive: try asset(named: TartRelease.archiveName),
      checksums: try asset(named: TartRelease.checksumsName(forTag: payload.tagName)))
  }
}

/// The fields of GitHub's release object the feed reads.
private struct GitHubRelease: Decodable {
  var tagName: String
  var htmlURL: URL
  var draft: Bool
  var prerelease: Bool
  var publishedAt: Date?
  var assets: [Asset]

  struct Asset: Decodable {
    var name: String
    var size: Int64
    var browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
      case name, size
      case browserDownloadURL = "browser_download_url"
    }
  }

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case draft, prerelease
    case publishedAt = "published_at"
    case assets
  }
}
