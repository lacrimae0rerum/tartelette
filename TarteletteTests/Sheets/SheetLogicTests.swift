import Foundation
import Testing

@testable import Tartelette

@Suite("Sheet logic")
struct SheetLogicTests {
  private let digest = "sha256:" + String(repeating: "ab12", count: 16)

  // MARK: ReferenceValidation

  @Test func acceptsValidReferences() {
    for reference in [
      "ghcr.io/cirruslabs/macos-tahoe-base:latest",
      "ghcr.io/cirruslabs/ubuntu",
      "ghcr.io/org/team/image:v1.2-rc_3",
      "localhost:5000/vm:1",
      "localhost/vm",
      "registry.example.com:8443/a/b",
      "10.0.0.5:5000/vm",
      "ghcr.io/org/image@\(digest)",
    ] {
      #expect(ReferenceValidation.problem(with: reference) == nil, "\(reference)")
    }
  }

  @Test func rejectsMalformedReferences() {
    for reference in [
      "",
      "https://ghcr.io/org/image",
      "ubuntu:latest",
      "ghcr.io/",
      "ghcr.io//image",
      "ghcr.io/org//image",
      "ghcr.io/org/image:",
      "ghcr.io/org/image:-bad",
      "ghcr.io/org/image@sha256:abc",
      "ghcr.io/org/image@sha256:" + String(repeating: "G", count: 64),
      "ghcr.io/org/image@sha256:" + String(repeating: "AB", count: 32),
      "ghcr.io/org/image@md5:" + String(repeating: "a", count: 64),
      "ghcr.io/org/image:tag@\(digest)",
      "localhost:99999/vm",
      "localhost:+50/vm",
      "my image/vm",
      ".ghcr.io/vm",
    ] {
      #expect(ReferenceValidation.problem(with: reference) != nil, "\(reference)")
    }
  }

  @Test func suggestsReadableLocalNames() {
    #expect(ReferenceValidation.suggestedLocalName(for: "ghcr.io/cirruslabs/macos-tahoe-base:latest") == "macos-tahoe-base")
    #expect(ReferenceValidation.suggestedLocalName(for: "ghcr.io/cirruslabs/ubuntu:24.04") == "ubuntu-24.04")
    #expect(ReferenceValidation.suggestedLocalName(for: "localhost:5000/vm") == "vm")
    #expect(ReferenceValidation.suggestedLocalName(for: "ghcr.io/org/image@\(digest)") == "image")
    #expect(ReferenceValidation.suggestedLocalName(for: "") == "vm")
  }

  // MARK: Names

  @Test func uniqueNamesSkipTakenOnes() {
    #expect(VMLibrary.uniqueName(basedOn: "dev", taken: []) == "dev")
    #expect(VMLibrary.uniqueName(basedOn: "dev", taken: ["dev"]) == "dev-2")
    #expect(VMLibrary.uniqueName(basedOn: "dev", taken: ["dev", "dev-2", "dev-3"]) == "dev-4")
  }

  @Test func newNamesMustBeValidAndFree() {
    #expect(VMLibrary.problemWithNewName("dev", existing: []) == nil)
    #expect(VMLibrary.problemWithNewName("dev", existing: ["dev"]) != nil)
    #expect(VMLibrary.problemWithNewName("dev", existing: ["dev"], allowExisting: true) == nil)
    #expect(VMLibrary.problemWithNewName("a/b", existing: []) != nil)
    #expect(VMLibrary.problemWithNewName("", existing: []) != nil)
  }

  // MARK: PruneEstimate

  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  private let gib = PruneEstimate.bytesPerGiB

  private func entry(_ name: String, gib count: UInt64, daysAgo: Double?) -> PruneEstimate.Entry {
    PruneEstimate.Entry(
      name: name, bytes: count * gib, accessed: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
  }

  @Test func listedSizesAreDecimalGigabytes() {
    #expect(PruneEstimate.bytes(listedGB: 2) == 2_000_000_000)
    #expect(PruneEstimate.bytes(listedGB: nil) == 0)
    #expect(PruneEstimate.bytes(listedGB: -1) == 0)
    #expect(PruneEstimate.bytes(listedGB: .nan) == 0)
    #expect(PruneEstimate.bytes(listedGB: .infinity) == 0)
  }

  @Test func budgetWalkIsDeterministicForEqualAndMissingDates() {
    // Same date (and no date) for every entry: only the name may decide the order.
    let entries = [
      entry("c", gib: 2, daysAgo: 3), entry("a", gib: 2, daysAgo: 3), entry("b", gib: 2, daysAgo: 3),
      entry("z", gib: 2, daysAgo: nil), entry("y", gib: 2, daysAgo: nil),
    ]
    let forward = PruneEstimate.affected(entries, olderThanDays: nil, spaceBudgetGiB: 4, now: now).map(\.name)
    let backward = PruneEstimate.affected(entries.reversed(), olderThanDays: nil, spaceBudgetGiB: 4, now: now).map(\.name)
    #expect(forward == backward)
    #expect(Set(forward) == ["c", "y", "z"], "a and b (by name) fit the 4 GiB budget among the newest")
  }

  @Test func ageCriterionUsesAccessDates() {
    let entries = [entry("new", gib: 1, daysAgo: 1), entry("old", gib: 1, daysAgo: 40), entry("never", gib: 1, daysAgo: nil)]
    let removed = PruneEstimate.affected(entries, olderThanDays: 30, spaceBudgetGiB: nil, now: now).map(\.name)
    #expect(Set(removed) == ["old", "never"])
  }

  @Test func spaceBudgetKeepsSmallerOlderEntriesThatStillFit() {
    // Tart walks newest first, keeps what fits and removes what doesn't, then keeps walking.
    let entries = [
      entry("a-newest", gib: 6, daysAgo: 1),
      entry("b", gib: 6, daysAgo: 2),
      entry("c-oldest", gib: 3, daysAgo: 3),
    ]
    let removed = PruneEstimate.affected(entries, olderThanDays: nil, spaceBudgetGiB: 10, now: now)
    #expect(removed.map(\.name) == ["b"])
  }

  @Test func spaceBudgetIsInGibibytes() {
    // 10 decimal GB fit in a 10 GiB budget (10 GiB > 10 GB).
    let entries = [PruneEstimate.Entry(name: "vm", bytes: PruneEstimate.bytes(listedGB: 10), accessed: now)]
    #expect(PruneEstimate.affected(entries, olderThanDays: nil, spaceBudgetGiB: 10, now: now).isEmpty)
    #expect(PruneEstimate.affected(entries, olderThanDays: nil, spaceBudgetGiB: 9, now: now).map(\.name) == ["vm"])
  }

  @Test func bothCriteriaApplyAgeFirst() {
    let entries = [
      entry("recent-big", gib: 8, daysAgo: 1),
      entry("recent-small", gib: 1, daysAgo: 2),
      entry("ancient", gib: 1, daysAgo: 90),
    ]
    let removed = PruneEstimate.affected(entries, olderThanDays: 30, spaceBudgetGiB: 8, now: now).map(\.name)
    // Equal sizes are ordered by name.
    #expect(removed == ["ancient", "recent-small"])
  }
}
