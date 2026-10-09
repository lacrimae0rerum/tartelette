#if DEBUG
import AppKit
import SwiftUI
import TarteletteKit

/// Development aid: renders the app's own windows to PNG files, so UI changes can be checked from
/// the command line without Screen Recording permission.
///
/// ```
/// open Tartelette.app --args -TarteletteSnapshot /tmp/shots \
///   -TarteletteSnapshotSelections "dashboard,vm:dev,activity,settings" -TarteletteSnapshotQuit YES
/// ```
/// Selections: `dashboard`, `images`, `registries`, `storage`, `activity`, `settings`,
/// `vm:<name>` or `vm:<name>:<tab>` (a `VMDetailTab` raw value), `sheet:<newVM|pull|import|prune|login>`,
/// `sheet:newVM:<image|macOS|linux|importArchive>`, `sheet:<clone|rename|push|export|delete|stop|run>:<name>`,
/// `menubar` (opens the menu bar extra), `start:<vm>` (headless), `launch:<vm>` (saved run profile),
/// `stop:<vm>`, `pbdump` (how this process reads the pasteboard), `cbdump:<vm>` (clipboard
/// history), `close` (closes
/// auxiliary windows).
enum DebugSnapshot {
  static func scheduleIfRequested(model: AppModel) {
    let defaults = UserDefaults.standard
    guard let directory = defaults.string(forKey: "TarteletteSnapshot") else { return }
    let selections = (defaults.string(forKey: "TarteletteSnapshotSelections") ?? "dashboard")
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let quit = defaults.bool(forKey: "TarteletteSnapshotQuit")
    let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      for (step, selection) in selections.enumerated() {
        apply(selection, model: model)
        try? await Task.sleep(for: .seconds(2.5))
        let name = String(format: "%02d-", step + 1)
          + selection.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        capture(named: name, into: folder)
        let inventory = NSApp.windows.map { window in
          "\(type(of: window)) id=\(window.identifier?.rawValue ?? "-") visible=\(window.isVisible) frame=\(window.frame)"
        }
        try? inventory.joined(separator: "\n").write(
          to: folder.appendingPathComponent("\(name).windows.txt"), atomically: true, encoding: .utf8)
        if !selection.hasPrefix("sheet") { model.navigation.presentedSheet = nil }
      }
      if quit {
        // A presented sheet blocks termination; dismiss it first.
        model.navigation.presentedSheet = nil
        try? await Task.sleep(for: .seconds(0.5))
        NSApp.terminate(nil)
      }
    }
  }

  private static func apply(_ selection: String, model: AppModel) {
    let parts = selection.split(separator: ":", maxSplits: 2).map(String.init)
    switch parts.first {
    case "dashboard": model.navigation.selection = .dashboard
    case "images": model.navigation.selection = .images
    case "registries": model.navigation.selection = .registries
    case "storage": model.navigation.selection = .storage
    case "activity": model.navigation.selection = .activity
    case "settings":
      model.navigation.openSettings()
    case "menubar":
      showMenuBarContent(model: model)
    case "start" where parts.count == 2:
      model.library.start(parts[1]) { $0.display = .headless }
    case "launch" where parts.count == 2:
      // Starts with the VM's saved run profile (Tart's window by default).
      model.library.start(parts[1])
    case "stop" where parts.count == 2:
      model.library.stop(parts[1])
    case "pbdump":
      // Records how this process reads the general pasteboard (diagnostics for file URL handling).
      let board = NSPasteboard.general
      let items = (board.pasteboardItems ?? []).map { $0.string(forType: .fileURL) ?? $0.types.map(\.rawValue).joined(separator: ",") }
      let objects = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
      let snapshot = PasteboardCodec.snapshot(board)?.files.map(\.lastPathComponent) ?? []
      let report = "items: \(items)\nreadObjects: \(objects.map(\.lastPathComponent))\nsnapshot: \(snapshot)\n"
      let folder = UserDefaults.standard.string(forKey: "TarteletteSnapshot") ?? NSTemporaryDirectory()
      try? report.write(toFile: (folder as NSString).appendingPathComponent("pbdump.txt"), atomically: true, encoding: .utf8)
    case "cbdump" where parts.count == 2:
      // Dumps a VM's clipboard history (diagnostics for live sync).
      let state = model.clipboard.state(for: parts[1])
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withTime, .withFractionalSeconds]
      let lines = state.events.reversed().map { "\(formatter.string(from: $0.date)) \($0.kind) \($0.message)" }
      let folder = UserDefaults.standard.string(forKey: "TarteletteSnapshot") ?? NSTemporaryDirectory()
      try? (lines.joined(separator: "\n") + "\n").write(
        toFile: (folder as NSString).appendingPathComponent("cbdump.txt"), atomically: true, encoding: .utf8)
    case "close":
      for window in NSApp.windows where window.isVisible && window.identifier?.rawValue != "main" {
        window.close()
      }
    case "vm" where parts.count >= 2:
      let tab = parts.count == 3 ? VMDetailTab(rawValue: parts[2]) : nil
      model.navigation.show(parts[1], tab: tab)
    case "sheet" where parts.count >= 2:
      if let route = sheetRoute(parts[1], argument: parts.count == 3 ? parts[2] : nil) {
        model.navigation.present(route)
      }
    default: break
    }
  }

  /// `sheet:<kind>[:<argument>]`, e.g. `sheet:newVM:linux`, `sheet:clone:dev`, `sheet:delete:a+b`.
  private static func sheetRoute(_ kind: String, argument: String?) -> SheetRoute? {
    switch (kind, argument) {
    case ("newVM", let tab): .newVM(initialTab: tab.flatMap(NewVMTab.init(rawValue:)) ?? .image)
    case ("pull", _): .pull
    case ("import", _): .importVM
    case ("prune", _): .prune
    case ("login", _): .login
    case ("clone", let name?): .clone(source: name)
    case ("rename", let name?): .rename(vm: name)
    case ("push", let name?): .push(vm: name)
    case ("export", let name?): .exportVM(vm: name)
    case ("delete", let names?): .confirmDelete(names: names.split(separator: "+").map(String.init))
    case ("stop", let name?): .stopOptions(vm: name)
    case ("run", let name?): .runWithOptions(vm: name)
    default: nil
    }
  }

  /// Hosts the menu bar extra's content in a regular window (the real panel closes as soon as the
  /// app isn't frontmost, which is always the case when launched from a script).
  private static func showMenuBarContent(model: AppModel) {
    let host = NSHostingView(rootView: MenuBarContentView().environment(model))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.identifier = NSUserInterfaceItemIdentifier("menubar-preview")
    window.contentView = host
    window.isReleasedWhenClosed = false
    window.center()
    window.orderFrontRegardless()
  }

  private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

  /// `CGWindowListCreateImage`, looked up at run time (it is unavailable to Swift in current SDKs).
  /// Capturing the app's own windows doesn't need Screen Recording permission.
  private static let windowImage: WindowImageFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(symbol, to: WindowImageFunction.self)
  }()

  private static func capture(named name: String, into folder: URL) {
    guard let windowImage else { return }
    for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
      // kCGWindowListOptionIncludingWindow = 1 << 3; kCGWindowImageBoundsIgnoreFraming = 1 << 0.
      guard let image = windowImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
        continue
      }
      let rep = NSBitmapImageRep(cgImage: image)
      guard let data = rep.representation(using: .png, properties: [:]) else { continue }
      let label = window.identifier?.rawValue.replacingOccurrences(of: "/", with: "-") ?? "window\(index)"
      try? data.write(to: folder.appendingPathComponent("\(name)__\(label).png"))
    }
  }
}
#endif
