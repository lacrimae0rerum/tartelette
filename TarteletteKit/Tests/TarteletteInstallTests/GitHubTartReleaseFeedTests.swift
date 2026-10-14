import Foundation
import Testing

import TarteletteInstall

@Suite("GitHub release feed for Tart")
struct GitHubTartReleaseFeedTests {
  @Test func asksGitHubForTheLatestReleaseOfOpenAITart() async throws {
    let client = StubHTTPClient(body: tart2_41_0LatestReleaseJSON)
    _ = try await GitHubTartReleaseFeed(client: client, userAgent: "Tartelette/1.1.0").latestRelease()

    #expect(client.requests.count == 1)
    let request = try #require(client.requests.first)
    #expect(request.url?.absoluteString == "https://api.github.com/repos/openai/tart/releases/latest")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Tartelette/1.1.0")
  }

  @Test func namesTarteletteInTheDefaultUserAgent() async throws {
    let client = StubHTTPClient(body: tart2_41_0LatestReleaseJSON)
    _ = try await GitHubTartReleaseFeed(client: client).latestRelease()
    #expect(client.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Tartelette") == true)
  }

  @Test func readsTheReleaseAndTheTwoAssetsTheInstallerNeeds() async throws {
    let client = StubHTTPClient(body: tart2_41_0LatestReleaseJSON)
    let release = try await GitHubTartReleaseFeed(client: client).latestRelease()

    #expect(release.version == TartVersion(major: 2, minor: 41, patch: 0))
    #expect(release.tag == "2.41.0")
    #expect(release.publishedAt == Date(timeIntervalSince1970: 1_791_926_305))
    #expect(release.pageURL.absoluteString == "https://github.com/openai/tart/releases/tag/2.41.0")
    #expect(
      release.archive
        == TartReleaseAsset(
          name: "tart.tar.gz",
          downloadURL: URL(string: "https://github.com/openai/tart/releases/download/2.41.0/tart.tar.gz")!,
          size: 22_951_976))
    #expect(
      release.checksums
        == TartReleaseAsset(
          name: "tart_2.41.0_checksums.txt",
          downloadURL: URL(string: "https://github.com/openai/tart/releases/download/2.41.0/tart_2.41.0_checksums.txt")!,
          size: 78))
  }

  @Test func picksTheAssetsByNameAmongOthersAndAcceptsAVPrefixedTag() async throws {
    let body = releaseJSON(
      tag: "v2.42.0", assets: ["tart-arm64.pkg", "tart_2.42.0_checksums.txt", "softnet.tar.gz", "tart.tar.gz"])
    let release = try await GitHubTartReleaseFeed(client: StubHTTPClient(body: body)).latestRelease()

    #expect(release.version == TartVersion(major: 2, minor: 42, patch: 0))
    #expect(release.tag == "v2.42.0")
    #expect(release.archive.name == "tart.tar.gz")
    #expect(release.archive.downloadURL.absoluteString == "https://example.com/v2.42.0/tart.tar.gz")
    #expect(release.archive.size == 103)
    #expect(release.checksums.name == "tart_2.42.0_checksums.txt")
    #expect(
      release.checksums.downloadURL.absoluteString == "https://example.com/v2.42.0/tart_2.42.0_checksums.txt")
    #expect(release.checksums.size == 101)
  }

  // MARK: - Failures

  /// What `latestRelease()` throws when the client answers with `client`, or nil when it succeeds.
  private func failure(answering client: StubHTTPClient) async -> (any Error)? {
    do {
      _ = try await GitHubTartReleaseFeed(client: client).latestRelease()
      return nil
    } catch {
      return error
    }
  }

  @Test func reportsOfflineAndOtherTransportErrorsAsNetworkFailures() async throws {
    let offline = URLError(.notConnectedToInternet)
    let error = try #require(await failure(answering: StubHTTPClient(.failure(offline))) as? TartReleaseError)

    #expect(error == .network(reason: offline.localizedDescription))
    #expect(
      error.errorDescription
        == "Tartelette couldn't reach GitHub to look for Tart releases. Check your internet connection and try again.")
    #expect(error.failureReason == offline.localizedDescription)

    let timeout = await failure(answering: StubHTTPClient(.failure(URLError(.timedOut))))
    #expect(timeout as? TartReleaseError == .network(reason: URLError(.timedOut).localizedDescription))
  }

  @Test func letsCancellationThrough() async {
    let error = await failure(answering: StubHTTPClient(.failure(CancellationError())))
    #expect(error is CancellationError)
  }

  @Test(arguments: [403, 429])
  func reportsAnExhaustedRateLimitWithItsResetTime(status: Int) async throws {
    let client = StubHTTPClient(
      status: status, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1791979840"],
      body: #"{"message": "API rate limit exceeded"}"#)
    let error = try #require(await failure(answering: client) as? TartReleaseError)

    let resetsAt = Date(timeIntervalSince1970: 1_791_979_840)
    #expect(error == .rateLimited(resetsAt: resetsAt))
    #expect(
      error.errorDescription
        == "GitHub limits how often Tartelette can look for Tart releases, and that limit has been reached. "
        + "Try again after \(resetsAt.formatted(date: .omitted, time: .shortened)).")
  }

  @Test func reportsAnExhaustedRateLimitWithoutAResetTime() async throws {
    let client = StubHTTPClient(status: 429, headers: ["X-RateLimit-Remaining": "0"], body: "")
    let error = try #require(await failure(answering: client) as? TartReleaseError)

    #expect(error == .rateLimited(resetsAt: nil))
    #expect(
      error.errorDescription
        == "GitHub limits how often Tartelette can look for Tart releases, and that limit has been reached. "
        + "Try again later.")
  }

  @Test func treatsA403WithRequestsLeftAsAnHTTPStatus() async throws {
    let client = StubHTTPClient(status: 403, headers: ["x-ratelimit-remaining": "42"], body: "{}")
    let error = try #require(await failure(answering: client) as? TartReleaseError)
    #expect(error == .httpStatus(403))
  }

  @Test func reportsNoReleaseFor404() async throws {
    let client = StubHTTPClient(status: 404, body: #"{"message":"Not Found"}"#)
    let error = try #require(await failure(answering: client) as? TartReleaseError)
    #expect(error == .noRelease)
    #expect(error.errorDescription == "GitHub doesn't list a published Tart release yet. Try again later.")
  }

  @Test(arguments: [301, 500, 503])
  func reportsOtherUnsuccessfulStatuses(status: Int) async throws {
    let error = try #require(await failure(answering: StubHTTPClient(status: status, body: "")) as? TartReleaseError)
    #expect(error == .httpStatus(status))
    #expect(
      error.errorDescription
        == "GitHub answered with HTTP status \(status) while Tartelette looked for Tart releases. Try again later.")
  }

  @Test(arguments: ["", "<html>Unicorn!</html>", #"{"tag_name": "2.41.0"}"#, "[]"])
  func reportsAnswersThatArentAReleaseAsUnexpected(body: String) async throws {
    let error = try #require(await failure(answering: StubHTTPClient(body: body)) as? TartReleaseError)
    #expect(error == .unexpectedResponse(reason: "The answer isn't a GitHub release description."))
    #expect(
      error.errorDescription
        == "Tartelette couldn't read GitHub's answer about the latest Tart release. Try again later; "
        + "if it keeps happening, look for a newer version of Tartelette.")
    #expect(error.failureReason == "The answer isn't a GitHub release description.")
  }

  @Test(arguments: ["SNAPSHOT", "nightly-2026-10-13", "2.41.0-rc1"])
  func reportsATagThatIsntAVersionAsUnexpected(tag: String) async throws {
    let client = StubHTTPClient(body: releaseJSON(tag: tag))
    let error = try #require(await failure(answering: client) as? TartReleaseError)
    #expect(error == .unexpectedResponse(reason: "The release tag “\(tag)” isn't a version number."))
  }

  @Test func refusesADraft() async throws {
    let client = StubHTTPClient(body: releaseJSON(draft: true))
    let error = try #require(await failure(answering: client) as? TartReleaseError)
    #expect(error == .notUsable(tag: "2.42.0", reason: .draft))
    #expect(
      error.errorDescription
        == "The latest Tart release (2.42.0) is still a draft, so Tartelette won't install it. Try again later.")
  }

  @Test func refusesAPrerelease() async throws {
    let client = StubHTTPClient(body: releaseJSON(prerelease: true))
    let error = try #require(await failure(answering: client) as? TartReleaseError)
    #expect(error == .notUsable(tag: "2.42.0", reason: .prerelease))
    #expect(
      error.errorDescription
        == "The latest Tart release (2.42.0) is a pre-release, so Tartelette won't install it. Try again later.")
  }

  @Test func namesAMissingArchive() async throws {
    let body = releaseJSON(assets: ["tart_2.42.0_checksums.txt", "tart.zip"])
    let error = try #require(await failure(answering: StubHTTPClient(body: body)) as? TartReleaseError)
    #expect(error == .missingAsset(name: "tart.tar.gz", tag: "2.42.0"))
    #expect(
      error.errorDescription
        == "Tart 2.42.0 on GitHub doesn't include “tart.tar.gz”, which Tartelette needs to install and verify it. "
        + "Try again later.")
  }

  @Test func namesMissingChecksums() async throws {
    let body = releaseJSON(assets: ["tart.tar.gz", "tart_2.41.0_checksums.txt", "checksums.txt"])
    let error = try #require(await failure(answering: StubHTTPClient(body: body)) as? TartReleaseError)
    #expect(error == .missingAsset(name: "tart_2.42.0_checksums.txt", tag: "2.42.0"))
    #expect(
      error.errorDescription
        == "Tart 2.42.0 on GitHub doesn't include “tart_2.42.0_checksums.txt”, which Tartelette needs to install "
        + "and verify it. Try again later.")
  }
}
