import Foundation
import Testing

import TarteletteInstall

@Suite("Release checksums")
struct TartChecksumsTests {
  /// `tart_2.41.0_checksums.txt` as published with Tart 2.41.0 (78 bytes).
  static let tart2_41_0 = "07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560  tart.tar.gz\n"
  static let archiveSHA256 = "07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560"
  static let otherSHA256 = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

  @Test func readsTheArchiveChecksumOfARealRelease() throws {
    #expect(Self.tart2_41_0.utf8.count == 78)
    let checksums = try TartChecksums(parsing: Self.tart2_41_0)
    #expect(try checksums.expectedSHA256(for: "tart.tar.gz") == Self.archiveSHA256)
  }

  @Test func acceptsOneSpaceTheBinaryMarkerUppercaseHexAndCRLF() throws {
    let text =
      "\(Self.otherSHA256.uppercased()) *tart.tar.gz\r\n"
      + "\(Self.archiveSHA256) softnet.tar.gz\r\n"
      + "\r\n"
      + "\(Self.otherSHA256)  file name with spaces.txt"
    let checksums = try TartChecksums(parsing: text)

    #expect(try checksums.expectedSHA256(for: "tart.tar.gz") == Self.otherSHA256)
    #expect(try checksums.expectedSHA256(for: "softnet.tar.gz") == Self.archiveSHA256)
    #expect(try checksums.expectedSHA256(for: "file name with spaces.txt") == Self.otherSHA256)
  }

  @Test(arguments: [
    ("07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc56  tart.tar.gz", 1),  // 63 digits
    ("07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc5600  tart.tar.gz", 1),  // 66 digits
    ("07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc56g  tart.tar.gz", 1),  // not hex
    ("07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560", 1),  // no file name
    ("07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560  ", 1),  // empty file name
    ("07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560\ttart.tar.gz", 1),  // tab
    ("  07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560  tart.tar.gz", 1),  // indented
    ("tart.tar.gz  07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560", 1),  // swapped
    ("SHA256 (tart.tar.gz) = 07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560", 1),  // BSD style
    ("\n07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560  softnet.tar.gz\n<html>", 3),
    (
      "07faafc77acc668fcfb2fbe97811622567fb89c650db401a470f72e7c4ddc560  tart.tar.gz\n"
        + "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90  tart.tar.gz", 2
    ),  // listed twice
  ])
  func rejectsMalformedLines(text: String, line: Int) throws {
    let error = try #require(throws: TartReleaseError.self) { try TartChecksums(parsing: text) }
    #expect(error == .malformedChecksums(line: line))
    #expect(
      error.errorDescription
        == "The checksums file of this Tart release is damaged (line \(line)), so Tartelette can't verify the "
        + "download. Try again later.")
  }

  @Test func namesAFileTheChecksumsDontList() throws {
    let checksums = try TartChecksums(parsing: "\(Self.archiveSHA256)  softnet.tar.gz\n")
    let error = try #require(throws: TartReleaseError.self) { try checksums.expectedSHA256(for: "tart.tar.gz") }
    #expect(error == .missingChecksum(fileName: "tart.tar.gz"))
    #expect(
      error.errorDescription
        == "The checksums file of this Tart release doesn't list “tart.tar.gz”, so Tartelette can't verify the "
        + "download. Try again later.")
    #expect(throws: TartReleaseError.missingChecksum(fileName: "tart.tar.gz")) {
      try TartChecksums(parsing: "").expectedSHA256(for: "tart.tar.gz")
    }
  }
}
