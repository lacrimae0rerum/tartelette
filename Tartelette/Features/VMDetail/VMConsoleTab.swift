import AppKit
import Observation
import SwiftUI
import TarteletteKit

/// One command run in the guest and its output.
///
/// Output is kept in fixed-size blocks: appending only touches the last block (so the view
/// re-renders one small block instead of the whole output) and trimming drops whole blocks.
@Observable
final class ConsoleRun: Identifiable {
  struct Line: Identifiable, Equatable {
    let id: Int
    let text: String
    let isError: Bool
  }

  struct Block: Identifiable, Equatable {
    let id: Int
    var lines: [Line]
  }

  let id = UUID()
  let command: String
  let startedAt = Date()
  private(set) var blocks: [Block] = []
  private(set) var exitCode: Int32?
  private(set) var finishedAt: Date?
  /// Lines dropped from the start once the output exceeded `lineLimit`.
  private(set) var droppedLineCount = 0
  /// Total lines ever appended; also the next line id, so ids stay unique after trimming.
  private(set) var appendedLineCount = 0
  fileprivate var operation: TartOperation?

  /// Keep at most this many lines on screen…
  static let lineLimit = 5_000
  /// …in blocks of this many lines.
  static let blockSize = 250

  init(command: String) {
    self.command = command
  }

  var isRunning: Bool { exitCode == nil }
  var lineCount: Int { blocks.reduce(0) { $0 + $1.lines.count } }
  var lines: [Line] { blocks.flatMap(\.lines) }

  func append(_ text: String, isError: Bool) {
    let line = Line(id: appendedLineCount, text: text, isError: isError)
    appendedLineCount += 1
    if let last = blocks.indices.last, blocks[last].lines.count < Self.blockSize {
      blocks[last].lines.append(line)
    } else {
      blocks.append(Block(id: line.id, lines: [line]))
    }
    // Drop whole blocks, which removes lines in chunks instead of one by one.
    while lineCount > Self.lineLimit, blocks.count > 1 {
      droppedLineCount += blocks.removeFirst().lines.count
    }
  }

  /// Records the exit; the failure message is appended unless the run already printed it.
  ///
  /// Checks every retained line (once per run, at most `lineLimit`), not just the last block: the
  /// message may have been streamed just before a new block began.
  func finish(_ code: Int32, message: String?) {
    if code != 0, let message, !message.isEmpty,
      !blocks.contains(where: { block in block.lines.contains { $0.text == message } })
    {
      append(message, isError: true)
    }
    exitCode = code
    finishedAt = .now
    operation = nil
  }

  func cancel() { operation?.cancel() }

  var transcript: String {
    (["$ \(command)"] + lines.map(\.text)).joined(separator: "\n")
  }
}

/// The console of one VM: its runs and command history. Kept per VM for the app's lifetime so
/// switching tabs or VMs doesn't lose output.
@Observable
final class ConsoleSession {
  private(set) var runs: [ConsoleRun] = []
  private(set) var history: [String] = []

  static let runLimit = 30

  var isBusy: Bool { runs.last?.isRunning == true }

  func run(_ command: String, in vmName: String, os: VMOperatingSystem, client: TartClient) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if history.last != trimmed { history.append(trimmed) }
    if history.count > 200 { history.removeFirst(history.count - 200) }

    let run = ConsoleRun(command: trimmed)
    runs.append(run)
    if runs.count > Self.runLimit { runs.removeFirst(runs.count - Self.runLimit) }

    // A login shell picks up the guest's PATH; the agent's environment only has PATH and TERM.
    let locale = os == .linux ? "LANG=C.UTF-8" : "LANG=en_US.UTF-8"
    let argv = ["/usr/bin/env", locale, "/bin/sh", "-lc", trimmed]
    let operation = client.stream(.exec(ExecOptions(name: vmName, command: argv)))
    run.operation = operation
    Task {
      for await event in operation.events {
        switch event {
        case .line(let text, let isError): run.append(text, isError: isError)
        case .progress(let fraction): run.append("\(Int((fraction * 100).rounded()))%", isError: false)
        case .finished(let code, let message): run.finish(code, message: message)
        case .started, .status: break
        }
      }
      if run.isRunning { run.finish(-1, message: "The command ended unexpectedly.") }
    }
  }

  func clear() {
    runs.removeAll { !$0.isRunning }
  }
}

/// Console sessions by VM name.
@MainActor
enum ConsoleSessions {
  private static var sessions: [String: ConsoleSession] = [:]

  static func session(for name: String) -> ConsoleSession {
    if let session = sessions[name] { return session }
    let session = ConsoleSession()
    sessions[name] = session
    return session
  }
}

/// Runs one-off commands in the guest (`tart exec`) and streams their output.
struct VMConsoleTab: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    let session = ConsoleSessions.session(for: vm.name)
    let os = model.library.os(of: vm.name)
    let status = model.clipboard.agentStatus(for: vm.name)

    if !vm.state.isRunning, session.runs.isEmpty {
      EmptyStateView(
        "The VM Isn't Running", systemImage: "terminal",
        message: "Start the VM to run commands in it. Commands run through the Tart Guest Agent."
      ) {
        Button("Start") { model.library.start(vm.name) }
          .buttonStyle(.borderedProminent)
      }
    } else {
      VStack(spacing: 0) {
        ConsoleToolbar(vm: vm, os: os, session: session)
        Divider()
        if case .unavailable(let reason) = status, vm.state.isRunning {
          InlineNotice(.warning, "The Tart Guest Agent isn't reachable, so commands will likely fail. \(reason)")
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        ConsoleOutput(session: session)
        Divider()
        ConsoleInput(vm: vm, os: os, session: session)
      }
    }
  }
}

private struct ConsoleToolbar: View {
  let vm: VMListing
  let os: VMOperatingSystem
  let session: ConsoleSession
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      Label(
        "Commands run as the guest agent's user in a login shell.",
        systemImage: "info.circle"
      )
      .labelStyle(.titleAndIcon)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .help("Very long output (over 256 KB) can lose data on macOS 15 and older guests because of a Tart transport issue.")
      Spacer()
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.runs.map(\.transcript).joined(separator: "\n\n"), forType: .string)
      } label: {
        Label("Copy Output", systemImage: "doc.on.doc")
      }
      .disabled(session.runs.isEmpty)
      Button {
        session.clear()
      } label: {
        Label("Clear", systemImage: "trash")
      }
      .disabled(session.runs.isEmpty)
      Button {
        model.library.openTerminal(vm.name)
      } label: {
        Label("Open Interactive Shell", systemImage: "apple.terminal")
      }
      .disabled(!vm.state.isRunning)
      .help("Opens “tart exec -i -t \(vm.name) \(os == .linux ? "bash" : "zsh")” in Terminal")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

private struct ConsoleOutput: View {
  let session: ConsoleSession

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if session.runs.isEmpty {
            Text("Type a command below, or pick one from Quick Commands.")
              .foregroundStyle(.tertiary)
              .padding(.top, 8)
          }
          ForEach(session.runs) { run in
            RunView(run: run)
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .onChange(of: session.runs.last?.appendedLineCount) {
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      .onChange(of: session.runs.count) {
        proxy.scrollTo("bottom", anchor: .bottom)
      }
    }
  }
}

private struct RunView: View {
  let run: ConsoleRun

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text("$ \(run.command)")
          .font(.system(.callout, design: .monospaced).weight(.semibold))
          .textSelection(.enabled)
        Spacer()
        if run.isRunning {
          ProgressView().controlSize(.mini)
          Button("Stop") { run.cancel() }
            .controlSize(.small)
        } else if let code = run.exitCode {
          ExitCodeChip(code: code, duration: (run.finishedAt ?? .now).timeIntervalSince(run.startedAt))
        }
      }
      if run.droppedLineCount > 0 {
        Text("\(run.droppedLineCount) earlier lines not shown")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(run.blocks) { block in
          OutputBlockView(block: block)
        }
      }
    }
  }
}

/// A block of console lines rendered as one selectable text. Equatable so SwiftUI skips blocks
/// that didn't change when a new line arrives.
private struct OutputBlockView: View, Equatable {
  let block: ConsoleRun.Block

  var body: some View {
    Text(attributed)
      .font(.system(.callout, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var attributed: AttributedString {
    var result = AttributedString()
    for (index, line) in block.lines.enumerated() {
      var piece = AttributedString(line.text + (index == block.lines.count - 1 ? "" : "\n"))
      if line.isError { piece.foregroundColor = .red }
      result += piece
    }
    return result
  }
}

private struct ExitCodeChip: View {
  let code: Int32
  let duration: TimeInterval

  var body: some View {
    let ok = code == 0
    Pill(
      title: ok ? "Exit 0 · \(Formatting.elapsed(duration))" : "Exit \(code)\(meaning)",
      systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill",
      tint: ok ? .green : .red)
  }

  private var meaning: String {
    switch code {
    case 125: " · couldn't start"
    case 127: " · command not found"
    case 130: " · interrupted"
    case let value where value > 128 && value < 160: " · signal \(value - 128)"
    default: ""
    }
  }
}

private struct ConsoleInput: View {
  let vm: VMListing
  let os: VMOperatingSystem
  let session: ConsoleSession
  @Environment(AppModel.self) private var model
  @State private var command = ""
  @State private var historyIndex: Int?
  @FocusState private var isFocused: Bool

  private var quickCommands: [(String, String)] {
    switch os {
    case .linux:
      [
        ("System version", "uname -a && cat /etc/os-release | head -4"), ("Uptime", "uptime"),
        ("Disk usage", "df -h /"), ("Memory", "free -h"), ("Network", "ip -brief address"),
        ("Top processes", "ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -15"),
      ]
    default:
      [
        ("System version", "sw_vers"), ("Uptime", "uptime"), ("Disk usage", "df -h /"),
        ("Memory", "vm_stat | head -10"), ("Network", "ifconfig en0 | grep inet"),
        ("Top processes", "ps -Ao pid,pcpu,pmem,comm -r | head -15"),
      ]
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "chevron.right")
        .foregroundStyle(.secondary)
        .font(.system(.body, design: .monospaced).weight(.semibold))
      TextField("Command", text: $command, prompt: Text("Run a command in \(vm.name)…"))
        .textFieldStyle(.plain)
        .font(.system(.body, design: .monospaced))
        .focused($isFocused)
        .onSubmit(run)
        .onKeyPress(.upArrow) { recall(-1) }
        .onKeyPress(.downArrow) { recall(1) }
        .disabled(!vm.state.isRunning)
      Menu {
        ForEach(quickCommands, id: \.1) { item in
          Button(item.0) {
            command = item.1
            run()
          }
        }
      } label: {
        Label("Quick Commands", systemImage: "bolt")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(!vm.state.isRunning || session.isBusy)
      Button("Run", action: run)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!vm.state.isRunning || session.isBusy || command.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
    .onAppear { isFocused = true }
  }

  private func run() {
    guard vm.state.isRunning, !session.isBusy, let client = model.context.client else { return }
    session.run(command, in: vm.name, os: os, client: client)
    command = ""
    historyIndex = nil
  }

  private func recall(_ step: Int) -> KeyPress.Result {
    let history = session.history
    guard !history.isEmpty else { return .ignored }
    let next = (historyIndex ?? history.count) + step
    if next >= history.count {
      historyIndex = nil
      command = ""
    } else {
      let clamped = max(0, next)
      historyIndex = clamped
      command = history[clamped]
    }
    return .handled
  }
}
