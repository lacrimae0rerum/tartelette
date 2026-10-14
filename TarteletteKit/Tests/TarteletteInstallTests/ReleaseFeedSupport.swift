import Foundation

import TarteletteInstall

/// The answer of `GET https://api.github.com/repos/openai/tart/releases/latest` for Tart 2.41.0,
/// trimmed to the fields the feed reads.
let tart2_41_0LatestReleaseJSON = #"""
  {
    "html_url": "https://github.com/openai/tart/releases/tag/2.41.0",
    "tag_name": "2.41.0",
    "draft": false,
    "prerelease": false,
    "published_at": "2026-10-13T21:18:25Z",
    "assets": [
      {
        "name": "tart.tar.gz",
        "size": 22951976,
        "browser_download_url": "https://github.com/openai/tart/releases/download/2.41.0/tart.tar.gz"
      },
      {
        "name": "tart_2.41.0_checksums.txt",
        "size": 78,
        "browser_download_url": "https://github.com/openai/tart/releases/download/2.41.0/tart_2.41.0_checksums.txt"
      }
    ]
  }
  """#

/// A release description like GitHub's, with the given tag, flags and asset names.
func releaseJSON(
  tag: String = "2.42.0", draft: Bool = false, prerelease: Bool = false,
  assets: [String] = ["tart.tar.gz", "tart_2.42.0_checksums.txt"]
) -> String {
  let assetObjects = assets.enumerated().map { index, name in
    #"{"name": "\#(name)", "size": \#(100 + index), "browser_download_url": "https://example.com/\#(tag)/\#(name)"}"#
  }
  return #"""
    {"html_url": "https://github.com/openai/tart/releases/tag/\#(tag)", "tag_name": "\#(tag)",
     "draft": \#(draft), "prerelease": \#(prerelease), "published_at": "2026-11-02T10:00:00Z",
     "assets": [\#(assetObjects.joined(separator: ", "))]}
    """#
}

/// An `HTTPClient` that answers every request with a fixed result and records the requests.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
  enum Answer {
    case response(status: Int, headers: [String: String] = [:], body: String)
    case failure(any Error)
  }

  private let answer: Answer
  private let lock = NSLock()
  private var recorded: [URLRequest] = []

  init(_ answer: Answer) {
    self.answer = answer
  }

  convenience init(status: Int = 200, headers: [String: String] = [:], body: String) {
    self.init(.response(status: status, headers: headers, body: body))
  }

  var requests: [URLRequest] {
    lock.withLock { recorded }
  }

  func httpData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    switch answer {
    case .response(let status, let headers, let body):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
      return (Data(body.utf8), response)
    case .failure(let error):
      throw error
    }
  }
}
