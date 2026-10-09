import AppKit
import Foundation
import Observation
import TarteletteKit

/// The composition root: owns every store and wires them together.
///
/// Views get it with `@Environment(AppModel.self) private var model` and use the stores:
/// `model.library`, `model.jobs`, `model.metrics`, `model.clipboard`, `model.profiles`,
/// `model.registries`, `model.settings`, `model.navigation`, `model.context`.
@Observable
final class AppModel {
  let settings: AppSettings
  let navigation: NavigationModel
  let context: TartContext
  let profiles: RunProfileStore
  let jobs: JobCenter
  let library: VMLibrary
  let clipboard: ClipboardCenter
  let metrics: MetricsCenter
  let registries: RegistryStore

  /// Called when anything shown in the Dock (badge, progress) may have changed.
  var onDockStateChange: () -> Void = {}
  private var started = false

  init() {
    let settings = AppSettings()
    let navigation = NavigationModel()
    let context = TartContext()
    let profiles = RunProfileStore(defaultEngine: { settings.defaultClipboardEngine })
    let jobs = JobCenter(context: context, settings: settings)
    let library = VMLibrary(context: context, settings: settings, profiles: profiles, jobs: jobs, navigation: navigation)
    let clipboard = ClipboardCenter(
      context: context, settings: settings, profiles: profiles, library: library, navigation: navigation)
    let metrics = MetricsCenter(context: context, settings: settings, library: library, clipboard: clipboard)

    self.settings = settings
    self.navigation = navigation
    self.context = context
    self.profiles = profiles
    self.jobs = jobs
    self.library = library
    self.clipboard = clipboard
    self.metrics = metrics
    self.registries = RegistryStore(jobs: jobs, settings: settings)

    context.reload(settings: settings)
    library.onChange.append { [weak clipboard, weak metrics] changes in
      clipboard?.handle(changes)
      metrics?.handle(changes)
    }
    library.onChange.append { [weak self] _ in self?.onDockStateChange() }
    jobs.onChange = { [weak self] in self?.onDockStateChange() }
  }

  /// Starts polling and sampling. Safe to call more than once.
  func start() {
    guard !started else { return }
    started = true
    library.startPolling()
    metrics.start()
    registries.refresh()
    Task {
      await library.refresh()
      clipboard.adoptRunningVMs()
    }
  }

  /// Re-detects Tart after the executable path, TART_HOME or environment settings changed.
  ///
  /// Does nothing unless the effective environment changed. Otherwise guest connections are
  /// rebuilt (`ClipboardCenter.reconnectAll()`): VMs that stay running are re-probed and their live
  /// sync resumes instead of silently stopping until the next restart.
  func reloadEnvironment() {
    guard context.reload(settings: settings) else { return }
    clipboard.reconnectAll()
    library.startPolling()
    metrics.start()
    registries.refresh()
  }

  /// Asks VMs started by this app to shut down (used on quit when enabled in Settings).
  func requestShutdownOfLaunchedVMs() {
    for name in library.launched.keys where library.isRunning(name) {
      library.requestShutdown(name)
    }
  }
}
