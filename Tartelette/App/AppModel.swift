import AppKit
import Foundation
import Observation
import TarteletteKit

/// The composition root: owns every store and wires them together.
///
/// Views get it with `@Environment(AppModel.self) private var model` and use the stores:
/// `model.library`, `model.jobs`, `model.metrics`, `model.clipboard`, `model.profiles`,
/// `model.registries`, `model.agents`, `model.settings`, `model.navigation`, `model.context`.
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
  let agents: AgentAccessStore

  /// Called when anything shown in the Dock (badge, progress) may have changed.
  var onDockStateChange: () -> Void = {}
  /// Whether `start()` ran (a duplicate instance quits before starting anything).
  private(set) var started = false
  private var reconnectTask: Task<Void, Never>?

  init() {
    let settings = AppSettings()
    let navigation = NavigationModel()
    let context = TartContext()
    let profiles = RunProfileStore(defaultEngine: { settings.defaultClipboardEngine })
    let jobs = JobCenter(context: context, settings: settings)
    let agents = AgentAccessStore(tartPaths: { context.paths })
    let library = VMLibrary(
      context: context, settings: settings, profiles: profiles, agents: agents, jobs: jobs, navigation: navigation)
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
    self.agents = agents

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
    agents.startWatching()
    Task {
      await library.refresh()
      clipboard.adoptRunningVMs()
    }
  }

  /// Re-detects Tart after the executable path, TART_HOME or environment settings changed.
  ///
  /// Does nothing unless the effective environment changed. Otherwise guest connections are
  /// rebuilt: sessions stop immediately, and once a listing from the new environment arrived the
  /// running VMs are re-probed, so live sync resumes instead of silently stopping.
  func reloadEnvironment() {
    guard context.reload(settings: settings) else { return }
    // Drop connections made under the old environment now, but re-adopt running VMs only once the
    // listing comes from the new one (a different TART_HOME holds different VMs).
    clipboard.disconnectAll()
    library.startPolling()
    metrics.start()
    registries.refresh()
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      await self?.library.refreshAndWait()
      guard let self, !Task.isCancelled else { return }
      self.clipboard.adoptRunningVMs()
    }
  }

  /// Asks VMs started by this app to shut down (used on quit when enabled in Settings).
  func requestShutdownOfLaunchedVMs() {
    for name in library.launched.keys where library.isRunning(name) {
      library.requestShutdown(name)
    }
  }
}
