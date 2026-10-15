import Foundation

/// Answers `URLSession` requests from a table of routes instead of the network.
///
/// Every test registers routes under its own host, so tests running in parallel don't collide.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Route {
    /// Answers with `status` and `headers`, then sends `chunks` one by one. With `finish: false` the
    /// response never completes, like a stalled connection.
    case respond(status: Int = 200, headers: [String: String] = [:], chunks: [Data], finish: Bool = true)
    /// Redirects to `location` with a 302.
    case redirect(to: URL)
    /// Fails like the network would.
    case fail(URLError.Code)
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var routes: [String: Route] = [:]
  nonisolated(unsafe) private static var requested: [String] = []

  static func register(_ url: URL, _ route: Route) {
    lock.withLock { routes[url.absoluteString] = route }
  }

  static func wasRequested(_ url: URL) -> Bool {
    lock.withLock { requested.contains(url.absoluteString) }
  }

  /// A session configuration that sends every request to this protocol.
  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return configuration
  }

  /// A fresh `https` address under a host unique to the caller.
  static func uniqueURL(_ path: String = "file", scheme: String = "https") -> URL {
    URL(string: "\(scheme)://\(UUID().uuidString.lowercased()).example.com/\(path)")!
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let route = Self.lock.withLock {
      Self.requested.append(url.absoluteString)
      return Self.routes[url.absoluteString]
    }
    switch route {
    case .respond(let status, let headers, let chunks, let finish):
      // A content type, as GitHub sends, keeps URLSession from holding the response back to sniff one.
      let fields = ["Content-Type": "application/octet-stream"].merging(headers) { _, given in given }
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      if finish { client?.urlProtocolDidFinishLoading(self) }
    case .redirect(let location):
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case nil:
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }
  }

  override func stopLoading() {}
}
