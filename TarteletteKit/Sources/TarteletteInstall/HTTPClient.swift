import Foundation

/// Sends one HTTP request and returns the body with the response.
///
/// The seam through which this module reaches the network, so tests never do.
public protocol HTTPClient: Sendable {
  func httpData(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
  public func httpData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, response)
  }
}
