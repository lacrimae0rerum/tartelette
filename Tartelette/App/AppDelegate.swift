import AppKit
import SwiftUI
import TarteletteKit

/// Dock integration (badge, progress, menu), reopen and termination behaviour.
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private let dockTile = DockTileController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Two copies (say, one in /Applications and a development build) would both poll the VMs and
    // run live clipboard sync against the same guests, overwriting each other's transfers.
    if let other = Self.otherRunningInstance() {
      other.activate()
      NSApp.terminate(nil)
      return
    }
    model.onDockStateChange = { [weak self] in self?.updateDock() }
    model.start()
    updateDock()
    #if DEBUG
    DebugSnapshot.scheduleIfRequested(model: model)
    #endif
  }

  /// Another running copy of this app (same bundle identifier, any location), if any.
  static func otherRunningInstance() -> NSRunningApplication? {
    // XCTest launches the app as its test host next to any copy already running.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
      let identifier = Bundle.main.bundleIdentifier
    else { return nil }
    let current = NSRunningApplication.current
    return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
      .first { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !model.settings.showMenuBarExtra
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if model.settings.stopVMsOnQuit { model.requestShutdownOfLaunchedVMs() }
    model.clipboard.stopAll()
    return .terminateNow
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { model.navigation.openMainWindow() }
    return true
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    DockMenuBuilder(model: model).makeMenu()
  }

  private func updateDock() {
    let running = model.library.runningCount
    NSApp.dockTile.badgeLabel = running > 0 ? String(running) : nil
    dockTile.update(progress: model.jobs.overallProgress)
  }
}

/// Draws a progress bar over the app icon while jobs report progress (like Finder copies).
final class DockTileController {
  private var progressView: DockProgressView?

  func update(progress: Double?) {
    let tile = NSApp.dockTile
    if let progress {
      if progressView == nil {
        let view = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
        tile.contentView = view
        progressView = view
      }
      progressView?.progress = progress
    } else if progressView != nil {
      tile.contentView = nil
      progressView = nil
    }
    tile.display()
  }
}

final class DockProgressView: NSView {
  var progress: Double = 0 {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSApp.applicationIconImage?.draw(in: bounds)
    let track = NSRect(
      x: bounds.width * 0.14, y: bounds.height * 0.1, width: bounds.width * 0.72, height: bounds.height * 0.1)
    let radius = track.height / 2
    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
    let inset = track.insetBy(dx: 2, dy: 2)
    let fill = NSRect(x: inset.minX, y: inset.minY, width: inset.width * min(max(progress, 0.02), 1), height: inset.height)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: fill, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
  }
}

/// Builds the Dock menu from the current VM list.
struct DockMenuBuilder {
  let model: AppModel

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    let library = model.library
    let running = library.runningVMs
    let stopped = library.vms.filter { !$0.state.isRunning }

    if !running.isEmpty {
      menu.addItem(.sectionHeader(title: "Running"))
      for vm in running {
        let item = NSMenuItem(title: vm.name, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: library.os(of: vm.name).systemImage, accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(ActionMenuItem("Show Window", systemImage: "macwindow") { library.showWindow(vm.name) })
        submenu.addItem(ActionMenuItem("Open Terminal", systemImage: "terminal") { library.openTerminal(vm.name) })
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem("Send Mac Clipboard", systemImage: "arrow.right.doc.on.clipboard") {
          Task { await model.clipboard.sendHostClipboard(to: vm.name) }
        })
        submenu.addItem(ActionMenuItem("Get VM Clipboard", systemImage: "arrow.down.doc") {
          Task { await model.clipboard.fetchGuestClipboard(from: vm.name) }
        })
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem("Shut Down", systemImage: "power") { library.requestShutdown(vm.name) })
        submenu.addItem(ActionMenuItem("Stop", systemImage: "stop.fill") { library.stop(vm.name) })
        item.submenu = submenu
        menu.addItem(item)
      }
    }
    if !stopped.isEmpty {
      if !running.isEmpty { menu.addItem(.separator()) }
      menu.addItem(.sectionHeader(title: "Start"))
      for vm in stopped.prefix(12) {
        let item = ActionMenuItem(vm.name, systemImage: "play.fill") { library.start(vm.name) }
        menu.addItem(item)
      }
    }
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem("New Virtual Machine…", systemImage: "plus") {
      model.navigation.present(.newVM(initialTab: .image))
    })
    return menu
  }
}

/// Makes `NSMenuItem`s that run closures (the Dock menu is built in AppKit).
final class MenuAction: NSObject {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  @objc func fire() {
    handler()
  }
}

func ActionMenuItem(_ title: String, systemImage: String? = nil, handler: @escaping () -> Void) -> NSMenuItem {
  let action = MenuAction(handler)
  let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
  item.target = action
  // The menu item keeps its target alive (`target` itself is weak).
  item.representedObject = action
  if let systemImage { item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
  return item
}
