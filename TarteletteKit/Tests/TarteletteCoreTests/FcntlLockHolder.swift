import Foundation

/// Holds an `fcntl` write lock on a file from a separate process, as `tart run` does.
///
/// Uses the system Perl (always present on macOS) so the tests don't depend on Python or the
/// Command Line Tools. Waits for the helper to confirm the lock, with a timeout, and reaps it.
final class FcntlLockHolder: @unchecked Sendable {
  enum Failure: Error, CustomStringConvertible {
    case notReady(String)

    var description: String {
      switch self {
      case .notReady(let detail): "The lock helper (/usr/bin/perl) never confirmed the lock: \(detail)"
      }
    }
  }

  // struct flock on Darwin: off_t l_start, off_t l_len, pid_t l_pid, short l_type, short l_whence.
  private static let script = """
    use strict; use Fcntl qw(F_SETLKW F_WRLCK SEEK_SET);
    $| = 1;
    open(my $fh, "+<", $ARGV[0]) or die "open: $!";
    my $lock = pack("q q l s s", 0, 0, 0, F_WRLCK, SEEK_SET);
    fcntl($fh, F_SETLKW, $lock) or die "fcntl: $!";
    print "locked\\n";
    sleep($ARGV[1]);
    """

  private let process = Process()
  private let lock = NSLock()
  private var output = ""

  init(file: URL, holdSeconds: Int = 30, readyTimeout: TimeInterval = 10) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", Self.script, file.path, String(holdSeconds)]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let ready = DispatchSemaphore(value: 0)
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      self.lock.lock()
      self.output += String(decoding: data, as: UTF8.self)
      let isLocked = self.output.contains("locked\n")
      self.lock.unlock()
      if isLocked { ready.signal() }
    }

    try process.run()
    guard ready.wait(timeout: .now() + readyTimeout) == .success else {
      stop()
      let error = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
      throw Failure.notReady(error.isEmpty ? "timed out after \(readyTimeout) s" : error)
    }
  }

  var pid: Int32 { process.processIdentifier }

  /// Terminates the helper and waits for it to exit, releasing the lock.
  func stop() {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }
}
