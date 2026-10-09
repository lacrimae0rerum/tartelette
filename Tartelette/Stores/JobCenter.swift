import AppKit
import Foundation
import Observation
import TarteletteKit
import UserNotifications

/// One `tart` invocation shown in Activity: its command line, live progress, output and outcome.
@Observable
final class Job: Identifiable {
  enum State: Equatable {
    case running
    case succeeded
    case failed(String)
    case cancelled

    var isFinished: Bool { self != .running }
  }

  struct Line: Identifiable, Equatable {
    let id: Int
    let text: String
    let isError: Bool
  }

  let id = UUID()
  let command: TartCommand
  let title: String
  let commandLine: String
  /// Jobs fed through stdin (e.g. `tart login --password-stdin`) can't be retried: the input is
  /// handed to Tart once and never retained, so secrets don't linger in the job history.
  let canRetry: Bool
  let startedAt = Date()
  private(set) var state: State = .running
  private(set) var progress: Double?
  private(set) var phase: String?
  private(set) var lines: [Line] = []
  private(set) var finishedAt: Date?
  private(set) var processIdentifier: Int32?
  fileprivate var operation: TartOperation?
  private var nextLineID = 0

  static let lineLimit = 2_000

  init(command: TartCommand, title: String?, standardInput: Data?) {
    self.command = command
    self.title = title ?? command.title
    self.commandLine = command.commandLine
    self.canRetry = standardInput == nil
  }

  var isActive: Bool { state == .running }
  var duration: TimeInterval { (finishedAt ?? .now).timeIntervalSince(startedAt) }

  /// Sends SIGINT; Tart cancels the work and cleans up its temporary files.
  func cancel() {
    guard isActive else { return }
    operation?.cancel()
  }

  fileprivate func apply(_ event: TartOperation.Event) {
    switch event {
    case .started(let pid):
      processIdentifier = pid
    case .line(let text, let isError):
      append(text, isError: isError)
    case .status(let text):
      phase = text
      progress = nil
      append(text, isError: false)
    case .progress(let value):
      progress = value
    case .finished(let exitCode, let message):
      finishedAt = .now
      operation = nil
      state = Self.finalState(exitCode: exitCode, message: message)
      if state == .succeeded, progress != nil { progress = 1 }
    }
  }

  /// Maps Tart's exit status to a job outcome. SIGINT (exit 130, or TartOperation's "Cancelled."
  /// when Tart printed nothing) is how jobs are cancelled, so it is not reported as a failure.
  static func finalState(exitCode: Int32, message: String?) -> State {
    if exitCode == 0 { return .succeeded }
    if message == "Cancelled." || exitCode == 128 + SIGINT { return .cancelled }
    return .failed(message ?? "Tart exited with code \(exitCode).")
  }

  fileprivate func fail(_ message: String) {
    finishedAt = .now
    state = .failed(message)
  }

  private func append(_ text: String, isError: Bool) {
    lines.append(Line(id: nextLineID, text: text, isError: isError))
    nextLineID += 1
    if lines.count > Self.lineLimit { lines.removeFirst(lines.count - Self.lineLimit) }
  }
}

/// Runs `tart` commands as observable jobs.
///
/// Sheets call `run(_:…)` for fire-and-forget operations (progress appears in Activity, the Dock
/// and the menu bar) or `await runAndWait(_:…)` when they need the outcome before dismissing.
@Observable
final class JobCenter {
  private(set) var jobs: [Job] = []
  private let context: TartContext
  private let settings: AppSettings
  /// Called whenever a job changes progress or finishes (Dock tile, menu bar).
  var onChange: () -> Void = {}
  private var notificationsAuthorized: Bool?

  static let historyLimit = 100

  init(context: TartContext, settings: AppSettings) {
    self.context = context
    self.settings = settings
  }

  var activeJobs: [Job] { jobs.filter(\.isActive) }
  var activeCount: Int { activeJobs.count }

  /// Average progress of running jobs that report it, for the Dock tile.
  var overallProgress: Double? {
    let values = activeJobs.compactMap(\.progress)
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  /// Starts `command` and returns its job immediately. `completion` runs on the main actor when
  /// the job finishes (successfully or not).
  @discardableResult
  func run(
    _ command: TartCommand,
    standardInput: Data? = nil,
    title: String? = nil,
    completion: ((Job) -> Void)? = nil
  ) -> Job {
    let job = Job(command: command, title: title, standardInput: standardInput)
    jobs.insert(job, at: 0)
    trimHistory()
    guard let client = context.client else {
      job.fail("Tart isn't installed or couldn't be found.")
      completion?(job)
      onChange()
      return job
    }
    requestNotificationAuthorizationIfNeeded(for: command)
    let operation = client.stream(command, standardInput: standardInput)
    job.operation = operation
    Task {
      for await event in operation.events {
        job.apply(event)
        if case .progress = event { onChange() }
      }
      if !job.state.isFinished { job.fail("The operation ended unexpectedly.") }
      onChange()
      notifyIfNeeded(job)
      completion?(job)
    }
    onChange()
    return job
  }

  /// Runs `command` and waits for it. Throws `JobError.failed` (with Tart's message) on failure
  /// and `CancellationError` when the user cancelled it.
  func runAndWait(_ command: TartCommand, standardInput: Data? = nil, title: String? = nil) async throws {
    let job: Job = await withCheckedContinuation { continuation in
      run(command, standardInput: standardInput, title: title) { continuation.resume(returning: $0) }
    }
    switch job.state {
    case .succeeded, .running: return
    case .cancelled: throw CancellationError()
    case .failed(let message): throw JobError.failed(message)
    }
  }

  /// Runs the job's command again (only for jobs that didn't take standard input).
  func retry(_ job: Job) {
    guard job.canRetry else { return }
    run(job.command, title: job.title)
  }

  func clearFinished() {
    jobs.removeAll { !$0.isActive }
  }

  func remove(_ job: Job) {
    guard !job.isActive else { return }
    jobs.removeAll { $0.id == job.id }
  }

  private func trimHistory() {
    let evicted = Self.evictionIndices(activeFlags: jobs.map(\.isActive), limit: Self.historyLimit)
    guard !evicted.isEmpty else { return }
    jobs = jobs.enumerated().filter { !evicted.contains($0.offset) }.map(\.element)
  }

  /// Indices of the jobs to drop so at most `limit` remain. `jobs` is ordered newest first, so the
  /// oldest finished jobs (from the end) go first; running jobs are never evicted.
  static func evictionIndices(activeFlags: [Bool], limit: Int) -> Set<Int> {
    var excess = activeFlags.count - limit
    guard excess > 0 else { return [] }
    var evicted: Set<Int> = []
    for index in activeFlags.indices.reversed() where excess > 0 && !activeFlags[index] {
      evicted.insert(index)
      excess -= 1
    }
    return evicted
  }

  // MARK: Notifications

  private func requestNotificationAuthorizationIfNeeded(for command: TartCommand) {
    guard settings.notifyOnCompletion, command.isLongRunning, notificationsAuthorized == nil else { return }
    notificationsAuthorized = false
    Task {
      let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
      notificationsAuthorized = granted
    }
  }

  private func notifyIfNeeded(_ job: Job) {
    guard settings.notifyOnCompletion, notificationsAuthorized == true, job.duration > 10, !NSApp.isActive else { return }
    let content = UNMutableNotificationContent()
    switch job.state {
    case .succeeded:
      content.title = job.title
      content.body = "Finished in \(Formatting.elapsed(job.duration))."
    case .failed(let message):
      content.title = "\(job.title) failed"
      content.body = message
    case .cancelled, .running:
      return
    }
    content.sound = .default
    let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
    Task { try? await UNUserNotificationCenter.current().add(request) }
  }
}

enum JobError: LocalizedError, Equatable {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}
