import Foundation
import Testing

@testable import Tartelette

@Suite("Job outcomes and history")
struct JobCenterTests {
  @Test func exitCodesMapToOutcomes() {
    #expect(Job.finalState(exitCode: 0, message: nil) == .succeeded)
    // SIGINT is how jobs are cancelled: 128 + SIGINT, or TartOperation's "Cancelled." marker.
    #expect(Job.finalState(exitCode: 130, message: nil) == .cancelled)
    #expect(Job.finalState(exitCode: 130, message: "interrupted") == .cancelled)
    #expect(Job.finalState(exitCode: 1, message: "Cancelled.") == .cancelled)
    #expect(Job.finalState(exitCode: 2, message: "VM \"x\" is not running") == .failed("VM \"x\" is not running"))
    #expect(Job.finalState(exitCode: 1, message: nil) == .failed("Tart exited with code 1."))
  }

  @Test func trimmingEvictsTheOldestFinishedJobs() {
    // Newest first: [finished, running, finished, finished(oldest)].
    let flags = [false, true, false, false]
    #expect(JobCenter.evictionIndices(activeFlags: flags, limit: 3) == [3])
    #expect(JobCenter.evictionIndices(activeFlags: flags, limit: 2) == [3, 2])
    // Running jobs are never evicted, even when that leaves more than the limit.
    #expect(JobCenter.evictionIndices(activeFlags: flags, limit: 1) == [3, 2, 0])
    #expect(JobCenter.evictionIndices(activeFlags: [true, true, true], limit: 1).isEmpty)
  }

  @Test func trimmingDoesNothingWithinTheLimit() {
    #expect(JobCenter.evictionIndices(activeFlags: [false, false], limit: 2).isEmpty)
    #expect(JobCenter.evictionIndices(activeFlags: [], limit: 0).isEmpty)
  }

  @Test func newestJobsSurviveWhenHistoryOverflows() {
    // 101 finished jobs (index 0 newest): only the oldest one goes.
    let flags = Array(repeating: false, count: JobCenter.historyLimit + 1)
    #expect(JobCenter.evictionIndices(activeFlags: flags, limit: JobCenter.historyLimit) == [JobCenter.historyLimit])
  }
}
