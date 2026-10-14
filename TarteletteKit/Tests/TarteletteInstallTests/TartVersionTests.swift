import Testing

import TarteletteInstall

@Suite("Tart versions")
struct TartVersionTests {
  @Test(arguments: [
    ("2.41.0", TartVersion(major: 2, minor: 41, patch: 0)),
    ("v2.41.0", TartVersion(major: 2, minor: 41, patch: 0)),
    ("2.41", TartVersion(major: 2, minor: 41, patch: 0)),
    ("2.40.1\n", TartVersion(major: 2, minor: 40, patch: 1)),
    ("  2.9.12 \n", TartVersion(major: 2, minor: 9, patch: 12)),
  ])
  func parsesReleaseTagsAndVersionOutput(text: String, expected: TartVersion) {
    let version = TartVersion(text)
    #expect(version == expected)
    #expect(version?.major == expected.major)
    #expect(version?.minor == expected.minor)
    #expect(version?.patch == expected.patch)
  }

  @Test(arguments: [
    "SNAPSHOT", "SNAPSHOT\n", "", "  ", "2", "2.", "2..1", ".2.1", "2.41.0.1", "2.41.x", "v", "vv2.41.0",
    "2.41.0-rc1", "2.-1.0", "+2.41.0", "tart 2.41.0", "2.41.0 (abc)", "２.４１.０",
    "2.99999999999999999999.0",
  ])
  func rejectsSnapshotAndGarbage(text: String) {
    #expect(TartVersion(text) == nil)
  }

  @Test func comparesComponentsNumerically() throws {
    let v2_9_0 = try #require(TartVersion("2.9.0"))
    let v2_10_0 = try #require(TartVersion("2.10.0"))
    let v2_40_1 = try #require(TartVersion("2.40.1"))
    let v2_41 = try #require(TartVersion("2.41"))
    let v2_41_0 = try #require(TartVersion("v2.41.0"))
    let v10_0_0 = try #require(TartVersion("10.0.0"))

    #expect(v2_9_0 < v2_10_0)
    #expect(!(v2_10_0 < v2_9_0))
    #expect(v2_40_1 < v2_41)
    #expect(v2_41 == v2_41_0)
    #expect(!(v2_41 < v2_41_0) && !(v2_41_0 < v2_41))
    #expect(v2_41_0 < v10_0_0)
    #expect(TartVersion(major: 2, minor: 41, patch: 1) > v2_41)
    #expect([v10_0_0, v2_41, v2_9_0, v2_40_1, v2_10_0].max() == v10_0_0)
    #expect([v10_0_0, v2_41, v2_9_0, v2_40_1, v2_10_0].sorted() == [v2_9_0, v2_10_0, v2_40_1, v2_41, v10_0_0])
  }

  @Test func describesItselfAsThreeComponents() {
    #expect(TartVersion("2.41")?.description == "2.41.0")
    #expect(TartVersion("v2.40.1")?.description == "2.40.1")
    #expect(String(describing: TartVersion(major: 3, minor: 0, patch: 7)) == "3.0.7")
  }
}
