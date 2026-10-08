import SwiftUI
import TarteletteKit

/// Every action for one VM, as menu buttons. Used by context menus, toolbar menus, the VM menu
/// and the menu bar extra so they always agree.
struct VMActionsMenu: View {
  let name: String
  var includesLifecycle = true

  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    let running = library.isRunning(name)

    if includesLifecycle {
      if running {
        StopMenuItems(name: name)
      } else {
        StartMenuItems(name: name)
      }
      Divider()
    }

    if running {
      Button("Show Window", systemImage: "macwindow") { library.showWindow(name) }
      Button("Open Terminal", systemImage: "terminal") { library.openTerminal(name) }
      Button("Open SSH Session", systemImage: "network") { Task { await library.openSSH(name) } }
      Button("Copy IP Address", systemImage: "number") { Task { await library.copyIP(name) } }
      Divider()
      Button("Send Mac Clipboard to VM", systemImage: "arrow.right.doc.on.clipboard") {
        Task { await model.clipboard.sendHostClipboard(to: name) }
      }
      Button("Get VM Clipboard", systemImage: "arrow.down.doc") {
        Task { await model.clipboard.fetchGuestClipboard(from: name) }
      }
      Divider()
    }

    Button("Clone…", systemImage: "plus.square.on.square") { model.navigation.present(.clone(source: name)) }
    Button("Rename…", systemImage: "pencil") { model.navigation.present(.rename(vm: name)) }
      .disabled(running)
    Button("Push to Registry…", systemImage: "icloud.and.arrow.up") { model.navigation.present(.push(vm: name)) }
      .disabled(running)
    Button("Export…", systemImage: "square.and.arrow.up") { model.navigation.present(.exportVM(vm: name)) }
    Button("Run Options…", systemImage: "slider.horizontal.3") { model.navigation.present(.runWithOptions(vm: name)) }
    Divider()
    Button("Show in Finder", systemImage: "folder") { library.revealInFinder(name) }
    Button("Show Log", systemImage: "doc.text") { library.revealLog(name) }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive) {
      model.navigation.present(.confirmDelete(names: [name]))
    }
    .disabled(running)
  }
}

/// The Start variants for a stopped or suspended VM.
struct StartMenuItems: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    let resumes = library.state(of: name) == .suspended
    Button(resumes ? "Resume" : "Start", systemImage: "play.fill") { library.start(name) }
    Button("Start Without Window", systemImage: "rectangle.dashed") {
      library.start(name) { $0.display = .headless }
    }
    Button("Start with Screen Sharing", systemImage: "rectangle.on.rectangle") {
      library.start(name) { $0.display = .vnc }
    }
    if library.os(of: name) == .macOS {
      Button("Start in Recovery", systemImage: "lifepreserver") {
        library.start(name) { $0.recovery = true }
      }
    }
    Button("Start with Options…", systemImage: "slider.horizontal.3") {
      model.navigation.present(.runWithOptions(vm: name))
    }
  }
}

/// The stop variants for a running VM.
struct StopMenuItems: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    Button("Shut Down", systemImage: "power") { library.requestShutdown(name) }
    Button("Stop", systemImage: "stop.fill") { library.stop(name) }
    if library.canSuspend(name) {
      Button("Suspend", systemImage: "pause.fill") { library.suspend(name) }
    }
    Button("Stop with Options…", systemImage: "timer") { model.navigation.present(.stopOptions(vm: name)) }
    Button("Force Stop…", systemImage: "xmark.octagon", role: .destructive) {
      model.navigation.confirm(
        "Force “\(name)” to stop?",
        message: "The VM is terminated immediately, like pulling the power cord. Unsaved work in the VM is lost.",
        actionTitle: "Force Stop"
      ) { library.forceStop(name) }
    }
  }
}
