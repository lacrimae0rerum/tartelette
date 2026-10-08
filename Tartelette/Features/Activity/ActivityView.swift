import AppKit
import SwiftUI
import TarteletteKit

/// Every `tart` command the app ran, with live progress, output and outcome.
struct ActivityView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let jobs = model.jobs.jobs
    Group {
      if jobs.isEmpty {
        EmptyStateView(
          "No Activity", systemImage: "list.bullet.rectangle",
          message: "Commands Tartelette runs — pulls, clones, pushes, exports — appear here with their progress and output.")
      } else {
        List {
          ForEach(jobs) { job in
            JobRow(job: job)
          }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
      }
    }
    .navigationTitle("Activity")
    .navigationSubtitle(model.jobs.activeCount > 0 ? "\(model.jobs.activeCount) running" : "")
    .toolbar {
      ToolbarItem {
        Button("Clear Finished", systemImage: "clear") { model.jobs.clearFinished() }
          .disabled(jobs.allSatisfy(\.isActive))
          .help("Remove finished commands")
      }
    }
  }
}

/// One job: state, title, command line, progress and an expandable log.
struct JobRow: View {
  let job: Job
  @Environment(AppModel.self) private var model
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        stateIcon
        VStack(alignment: .leading, spacing: 2) {
          Text(job.title).font(.headline).lineLimit(1)
          Text(job.commandLine)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        Spacer(minLength: 8)
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text(Formatting.elapsed(job.duration))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        actions
      }

      if job.isActive {
        VStack(alignment: .leading, spacing: 3) {
          if let progress = job.progress {
            ProgressView(value: progress)
          } else {
            ProgressView().progressViewStyle(.linear)
          }
          if let phase = job.phase {
            Text(phase + (job.progress.map { " — \(Formatting.percent($0 * 100))" } ?? ""))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      } else if case .failed(let message) = job.state {
        Text(message)
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .lineLimit(4)
      }

      if !job.lines.isEmpty {
        DisclosureGroup(isExpanded: $isExpanded) {
          JobLog(lines: job.lines)
        } label: {
          Text(job.lines.count == 1 ? "Output (1 line)" : "Output (\(job.lines.count) lines)").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 6)
    .contextMenu {
      Button("Copy Command", systemImage: "doc.on.doc") { copy(job.commandLine) }
      Button("Copy Output", systemImage: "text.alignleft") { copy(job.lines.map(\.text).joined(separator: "\n")) }
      if !job.isActive {
        Divider()
        Button("Run Again", systemImage: "arrow.clockwise") { model.jobs.retry(job) }
        Button("Remove", systemImage: "trash") { model.jobs.remove(job) }
      }
    }
  }

  @ViewBuilder private var stateIcon: some View {
    switch job.state {
    case .running:
      ProgressView().controlSize(.small).frame(width: 18)
    case .succeeded:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18)
    case .failed:
      Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).frame(width: 18)
    case .cancelled:
      Image(systemName: "stop.circle").foregroundStyle(.secondary).frame(width: 18)
    }
  }

  @ViewBuilder private var actions: some View {
    if job.isActive {
      Button("Cancel") { job.cancel() }
        .controlSize(.small)
        .help("Stop this command (Tart cleans up temporary files)")
    } else if case .failed = job.state {
      Button("Retry") { model.jobs.retry(job) }
        .controlSize(.small)
    } else if case .cancelled = job.state {
      Button("Retry") { model.jobs.retry(job) }
        .controlSize(.small)
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// A monospaced, selectable, auto-scrolling log.
struct JobLog: View {
  let lines: [Job.Line]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(lines) { line in
            Text(line.text)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(line.isError ? Color.red : Color.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(line.id)
          }
        }
        .textSelection(.enabled)
        .padding(8)
      }
      .frame(minHeight: 80, maxHeight: 220)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
      .onChange(of: lines.last?.id) { _, last in
        if let last { proxy.scrollTo(last, anchor: .bottom) }
      }
      .onAppear {
        if let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
      }
    }
  }
}
