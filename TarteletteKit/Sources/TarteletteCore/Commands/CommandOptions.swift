import Foundation

// Typed mirrors of every `tart` subcommand's arguments. Each type renders its own argv via
// `arguments`; defaults are omitted from argv so the rendered command stays minimal and readable.

public enum OutputFormat: String, Sendable, Hashable, CaseIterable {
  case text, json
}

// MARK: - create

public struct CreateOptions: Sendable, Hashable {
  public enum Source: Sendable, Hashable {
    /// `--from-ipsw <path|URL|latest>`
    case macOS(ipsw: String)
    /// `--linux`
    case linux
  }

  public static let defaultDiskSizeGB = 50

  public var name: String
  public var source: Source
  public var diskSizeGB: Int?
  public var diskFormat: DiskFormat?

  public init(name: String, source: Source, diskSizeGB: Int? = nil, diskFormat: DiskFormat? = nil) {
    self.name = name
    self.source = source
    self.diskSizeGB = diskSizeGB
    self.diskFormat = diskFormat
  }

  public var arguments: [String] {
    var args = ["create", name]
    switch source {
    case .macOS(let ipsw): args += ["--from-ipsw", ipsw]
    case .linux: args.append("--linux")
    }
    if let diskSizeGB, diskSizeGB != Self.defaultDiskSizeGB { args += ["--disk-size", String(diskSizeGB)] }
    if let diskFormat, diskFormat != .raw { args += ["--disk-format", diskFormat.rawValue] }
    return args
  }
}

// MARK: - clone

public struct CloneOptions: Sendable, Hashable {
  public static let defaultConcurrency = 4
  public static let defaultPruneLimitGB = 100

  public var source: String
  public var newName: String
  public var insecure: Bool
  public var concurrency: Int?
  /// `--deduplicate` (hidden): reuse layers of a similar cached image as the base.
  public var deduplicate: Bool
  /// `--stacked`: use the source image as an immutable base disk (macOS 27+, remote macOS images).
  public var stacked: Bool
  /// `--overwrite`: replace an existing local VM with the same name.
  public var overwrite: Bool
  /// `--prune-limit`: cap automatic pruning at this many GiB.
  public var pruneLimitGB: Int?

  public init(
    source: String,
    newName: String,
    insecure: Bool = false,
    concurrency: Int? = nil,
    deduplicate: Bool = false,
    stacked: Bool = false,
    overwrite: Bool = false,
    pruneLimitGB: Int? = nil
  ) {
    self.source = source
    self.newName = newName
    self.insecure = insecure
    self.concurrency = concurrency
    self.deduplicate = deduplicate
    self.stacked = stacked
    self.overwrite = overwrite
    self.pruneLimitGB = pruneLimitGB
  }

  public var arguments: [String] {
    var args = ["clone", source, newName]
    if insecure { args.append("--insecure") }
    if let concurrency, concurrency != Self.defaultConcurrency { args += ["--concurrency", String(concurrency)] }
    if deduplicate { args.append("--deduplicate") }
    if stacked { args.append("--stacked") }
    if overwrite { args.append("--overwrite") }
    if let pruneLimitGB, pruneLimitGB != Self.defaultPruneLimitGB { args += ["--prune-limit", String(pruneLimitGB)] }
    return args
  }
}

// MARK: - run

public struct RunOptions: Sendable, Hashable, Codable {
  public enum DisplayMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Tart's built-in window (default).
    case window
    /// `--no-graphics`
    case headless
    /// `--vnc` (macOS Screen Sharing; supports clipboard and drag & drop).
    case vnc
    /// `--vnc-experimental` (Virtualization.framework VNC server; works in recovery/installation).
    case vncExperimental
  }

  public enum Network: Sendable, Hashable, Codable {
    /// Default shared (NAT) networking.
    case shared
    /// `--net-bridged <interface>` (repeatable; one NIC per interface, BSD or display name).
    case bridged(interfaces: [String])
    /// `--net-softnet` plus optional allow/block/expose lists.
    case softnet(SoftnetOptions)
    /// `--net-host`
    case hostOnly
  }

  public struct SoftnetOptions: Sendable, Hashable, Codable {
    /// CIDRs for `--net-softnet-allow`.
    public var allow: [String]
    /// CIDRs for `--net-softnet-block`.
    public var block: [String]
    /// `EXTERNAL:INTERNAL` port specs for `--net-softnet-expose`.
    public var expose: [String]

    public init(allow: [String] = [], block: [String] = [], expose: [String] = []) {
      self.allow = allow
      self.block = block
      self.expose = expose
    }
  }

  public enum DiskSync: String, Sendable, Hashable, Codable, CaseIterable {
    /// `sync=none`. Named `disabled` so it never collides with `Optional.none`.
    case disabled = "none"
    case fsync
    case full
  }
  public enum DiskCaching: String, Sendable, Hashable, Codable, CaseIterable { case automatic, cached, uncached }

  public struct DiskAttachment: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Disk image path, block device, cached remote VM name or NBD URL.
    public var location: String
    public var readOnly: Bool
    public var sync: DiskSync?
    public var caching: DiskCaching?

    public init(
      id: UUID = UUID(),
      location: String,
      readOnly: Bool = false,
      sync: DiskSync? = nil,
      caching: DiskCaching? = nil
    ) {
      self.id = id
      self.location = location
      self.readOnly = readOnly
      self.sync = sync
      self.caching = caching
    }

    public var argument: String {
      var options: [String] = []
      if readOnly { options.append("ro") }
      if let sync { options.append("sync=\(sync.rawValue)") }
      if let caching { options.append("caching=\(caching.rawValue)") }
      return options.isEmpty ? location : "\(location):\(options.joined(separator: ","))"
    }
  }

  public struct DirectoryShare: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Optional directory name inside the mount point (required when several shares use one tag).
    public var name: String?
    public var path: String
    public var readOnly: Bool
    /// Mount tag; nil means Tart's default `com.apple.virtio-fs.automount`.
    public var tag: String?

    public init(id: UUID = UUID(), name: String? = nil, path: String, readOnly: Bool = false, tag: String? = nil) {
      self.id = id
      self.name = name
      self.path = path
      self.readOnly = readOnly
      self.tag = tag
    }

    public var argument: String {
      var options: [String] = []
      if readOnly { options.append("ro") }
      if let tag, !tag.isEmpty { options.append("tag=\(tag)") }
      let prefix = name.flatMap { $0.isEmpty ? nil : "\($0):" } ?? ""
      let suffix = options.isEmpty ? "" : ":\(options.joined(separator: ","))"
      return prefix + path + suffix
    }
  }

  public struct RootDiskOptions: Sendable, Hashable, Codable {
    /// Accepted by Tart but currently not applied (the root disk is always read-write).
    public var readOnly: Bool
    public var sync: DiskSync?
    public var caching: DiskCaching?

    public init(readOnly: Bool = false, sync: DiskSync? = nil, caching: DiskCaching? = nil) {
      self.readOnly = readOnly
      self.sync = sync
      self.caching = caching
    }

    public var isDefault: Bool { !readOnly && sync == nil && caching == nil }

    public var argument: String {
      var options: [String] = []
      if readOnly { options.append("ro") }
      if let sync { options.append("sync=\(sync.rawValue)") }
      if let caching { options.append("caching=\(caching.rawValue)") }
      return options.joined(separator: ",")
    }
  }

  /// `--provisioning-opts` (macOS 27+ hosts and guests, first boot only).
  public struct Provisioning: Sendable, Hashable, Codable {
    public var fullName: String?
    public var username: String?
    public var password: String?
    public var logsInAutomatically: Bool?
    public var enablesRemoteLogin: Bool?

    public init(
      fullName: String? = nil,
      username: String? = nil,
      password: String? = nil,
      logsInAutomatically: Bool? = nil,
      enablesRemoteLogin: Bool? = nil
    ) {
      self.fullName = fullName
      self.username = username
      self.password = password
      self.logsInAutomatically = logsInAutomatically
      self.enablesRemoteLogin = enablesRemoteLogin
    }

    public var isEmpty: Bool { argument.isEmpty }

    public var argument: String {
      var pairs: [String] = []
      if let fullName, !fullName.isEmpty { pairs.append("fullName=\(fullName)") }
      if let username, !username.isEmpty { pairs.append("username=\(username)") }
      if let password, !password.isEmpty { pairs.append("password=\(password)") }
      if let logsInAutomatically { pairs.append("logsInAutomatically=\(logsInAutomatically)") }
      if let enablesRemoteLogin { pairs.append("enablesRemoteLogin=\(enablesRemoteLogin)") }
      return pairs.joined(separator: ",")
    }
  }

  public var name: String
  public var display: DisplayMode
  /// `--graphics` (private): also show Tart's window when a VNC mode is selected.
  public var showWindowWithVNC: Bool
  public var network: Network
  public var directories: [DirectoryShare]
  public var disks: [DiskAttachment]
  public var rootDisk: RootDiskOptions
  /// `--rosetta <tag>` (Linux guests).
  public var rosettaTag: String?
  public var serial: Bool
  public var serialPath: String?
  public var noAudio: Bool
  public var noUSBAccessories: Bool
  public var noClipboard: Bool
  public var recovery: Bool
  public var nested: Bool
  public var suspendable: Bool
  public var captureSystemKeys: Bool
  public var noTrackpad: Bool
  public var noPointer: Bool
  public var noKeyboard: Bool
  public var provisioning: Provisioning?

  public init(
    name: String,
    display: DisplayMode = .window,
    showWindowWithVNC: Bool = false,
    network: Network = .shared,
    directories: [DirectoryShare] = [],
    disks: [DiskAttachment] = [],
    rootDisk: RootDiskOptions = RootDiskOptions(),
    rosettaTag: String? = nil,
    serial: Bool = false,
    serialPath: String? = nil,
    noAudio: Bool = false,
    noUSBAccessories: Bool = false,
    noClipboard: Bool = false,
    recovery: Bool = false,
    nested: Bool = false,
    suspendable: Bool = false,
    captureSystemKeys: Bool = false,
    noTrackpad: Bool = false,
    noPointer: Bool = false,
    noKeyboard: Bool = false,
    provisioning: Provisioning? = nil
  ) {
    self.name = name
    self.display = display
    self.showWindowWithVNC = showWindowWithVNC
    self.network = network
    self.directories = directories
    self.disks = disks
    self.rootDisk = rootDisk
    self.rosettaTag = rosettaTag
    self.serial = serial
    self.serialPath = serialPath
    self.noAudio = noAudio
    self.noUSBAccessories = noUSBAccessories
    self.noClipboard = noClipboard
    self.recovery = recovery
    self.nested = nested
    self.suspendable = suspendable
    self.captureSystemKeys = captureSystemKeys
    self.noTrackpad = noTrackpad
    self.noPointer = noPointer
    self.noKeyboard = noKeyboard
    self.provisioning = provisioning
  }

  public var arguments: [String] {
    var args = ["run", name]

    switch display {
    case .window: break
    case .headless: args.append("--no-graphics")
    case .vnc: args.append("--vnc")
    case .vncExperimental: args.append("--vnc-experimental")
    }
    if showWindowWithVNC, display == .vnc || display == .vncExperimental { args.append("--graphics") }

    if serial { args.append("--serial") }
    if let serialPath, !serialPath.isEmpty { args += ["--serial-path", serialPath] }
    if noAudio { args.append("--no-audio") }
    if noUSBAccessories { args.append("--no-usb-accessories") }
    if noClipboard { args.append("--no-clipboard") }
    if recovery { args.append("--recovery") }

    for disk in disks where !disk.location.isEmpty { args += ["--disk", disk.argument] }
    if let rosettaTag, !rosettaTag.isEmpty { args += ["--rosetta", rosettaTag] }
    for directory in directories where !directory.path.isEmpty { args += ["--dir", directory.argument] }
    if nested { args.append("--nested") }

    switch network {
    case .shared: break
    case .bridged(let interfaces):
      for interface in interfaces where !interface.isEmpty { args += ["--net-bridged", interface] }
    case .softnet(let softnet):
      args.append("--net-softnet")
      if !softnet.allow.isEmpty { args += ["--net-softnet-allow", softnet.allow.joined(separator: ",")] }
      if !softnet.block.isEmpty { args += ["--net-softnet-block", softnet.block.joined(separator: ",")] }
      if !softnet.expose.isEmpty { args += ["--net-softnet-expose", softnet.expose.joined(separator: ",")] }
    case .hostOnly: args.append("--net-host")
    }

    if !rootDisk.isDefault { args += ["--root-disk-opts", rootDisk.argument] }
    if suspendable { args.append("--suspendable") }
    if captureSystemKeys { args.append("--capture-system-keys") }
    if noTrackpad { args.append("--no-trackpad") }
    if noPointer { args.append("--no-pointer") }
    if noKeyboard { args.append("--no-keyboard") }
    if let provisioning, !provisioning.isEmpty { args += ["--provisioning-opts", provisioning.argument] }

    return args
  }

  /// A copy with the provisioning password masked, for display and logs.
  public var redacted: RunOptions {
    var copy = self
    if copy.provisioning?.password?.isEmpty == false { copy.provisioning?.password = "••••••" }
    return copy
  }
}

// MARK: - set

public struct SetOptions: Sendable, Hashable {
  public var name: String
  public var cpuCount: Int?
  public var memoryMB: UInt64?
  /// `WIDTHxHEIGHT[pt|px]`. Tart overwrites the unit every time, so include it to keep it.
  public var display: String?
  /// true → `--display-refit`, false → `--no-display-refit`.
  ///
  /// Tart resets `displayRefit` to "unset" on every `set` that omits both flags, so callers should
  /// carry the current value from `config.json` to preserve it.
  public var displayRefit: Bool?
  public var randomMAC: Bool
  public var randomSerial: Bool
  /// Replace the disk contents with the image at this path.
  public var diskPath: String?
  /// Grow the disk to this size (GB). Shrinking is not supported by Tart.
  public var diskSizeGB: Int?

  public init(
    name: String,
    cpuCount: Int? = nil,
    memoryMB: UInt64? = nil,
    display: String? = nil,
    displayRefit: Bool? = nil,
    randomMAC: Bool = false,
    randomSerial: Bool = false,
    diskPath: String? = nil,
    diskSizeGB: Int? = nil
  ) {
    self.name = name
    self.cpuCount = cpuCount
    self.memoryMB = memoryMB
    self.display = display
    self.displayRefit = displayRefit
    self.randomMAC = randomMAC
    self.randomSerial = randomSerial
    self.diskPath = diskPath
    self.diskSizeGB = diskSizeGB
  }

  public var hasChanges: Bool { arguments.count > 2 }

  public var arguments: [String] {
    var args = ["set", name]
    if let cpuCount { args += ["--cpu", String(cpuCount)] }
    if let memoryMB { args += ["--memory", String(memoryMB)] }
    if let display, !display.isEmpty { args += ["--display", display] }
    if let displayRefit { args.append(displayRefit ? "--display-refit" : "--no-display-refit") }
    if randomMAC { args.append("--random-mac") }
    if randomSerial { args.append("--random-serial") }
    if let diskPath, !diskPath.isEmpty { args += ["--disk", diskPath] }
    if let diskSizeGB { args += ["--disk-size", String(diskSizeGB)] }
    return args
  }
}

// MARK: - list / get

public struct ListOptions: Sendable, Hashable {
  public var source: VMSource?
  public var format: OutputFormat
  public var quiet: Bool

  public init(source: VMSource? = nil, format: OutputFormat = .json, quiet: Bool = false) {
    self.source = source
    self.format = format
    self.quiet = quiet
  }

  public var arguments: [String] {
    var args = ["list"]
    if let source { args += ["--source", source.rawValue] }
    if format != .text { args += ["--format", format.rawValue] }
    if quiet { args.append("--quiet") }
    return args
  }
}

// MARK: - login

/// `tart login`. The password is never part of argv: it is written to the child's standard input
/// (`--password-stdin`), because without it Tart prompts on /dev/tty.
public struct LoginOptions: Sendable, Hashable {
  public var host: String
  public var username: String
  public var insecure: Bool
  public var noValidate: Bool

  public init(host: String, username: String, insecure: Bool = false, noValidate: Bool = false) {
    self.host = host
    self.username = username
    self.insecure = insecure
    self.noValidate = noValidate
  }

  public var arguments: [String] {
    var args = ["login", host, "--username", username, "--password-stdin"]
    if insecure { args.append("--insecure") }
    if noValidate { args.append("--no-validate") }
    return args
  }
}

// MARK: - ip

public struct IPOptions: Sendable, Hashable {
  public enum Resolver: String, Sendable, Hashable, CaseIterable, Codable {
    case dhcp, arp, agent
  }

  public var name: String
  public var waitSeconds: Int?
  public var resolver: Resolver

  public init(name: String, waitSeconds: Int? = nil, resolver: Resolver = .dhcp) {
    self.name = name
    self.waitSeconds = waitSeconds
    self.resolver = resolver
  }

  public var arguments: [String] {
    var args = ["ip", name]
    if let waitSeconds, waitSeconds > 0 { args += ["--wait", String(waitSeconds)] }
    if resolver != .dhcp { args += ["--resolver", resolver.rawValue] }
    return args
  }
}

// MARK: - exec

public struct ExecOptions: Sendable, Hashable {
  public var name: String
  /// `-i`: attach standard input.
  public var interactive: Bool
  /// `-t`: allocate a pseudo-terminal.
  public var allocateTTY: Bool
  public var command: [String]

  public init(name: String, command: [String], interactive: Bool = false, allocateTTY: Bool = false) {
    self.name = name
    self.command = command
    self.interactive = interactive
    self.allocateTTY = allocateTTY
  }

  public var arguments: [String] {
    var args = ["exec"]
    if interactive { args.append("-i") }
    if allocateTTY { args.append("-t") }
    args.append(name)
    args += command
    return args
  }
}

// MARK: - pull / push

public struct PullOptions: Sendable, Hashable {
  public var remoteName: String
  public var insecure: Bool
  public var concurrency: Int?
  /// `--deduplicate` (hidden).
  public var deduplicate: Bool

  public init(remoteName: String, insecure: Bool = false, concurrency: Int? = nil, deduplicate: Bool = false) {
    self.remoteName = remoteName
    self.insecure = insecure
    self.concurrency = concurrency
    self.deduplicate = deduplicate
  }

  public var arguments: [String] {
    var args = ["pull", remoteName]
    if insecure { args.append("--insecure") }
    if let concurrency, concurrency != CloneOptions.defaultConcurrency { args += ["--concurrency", String(concurrency)] }
    if deduplicate { args.append("--deduplicate") }
    return args
  }
}

public struct PushOptions: Sendable, Hashable {
  public struct Label: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
      self.id = id
      self.key = key
      self.value = value
    }
  }

  public var localName: String
  public var remoteNames: [String]
  public var insecure: Bool
  public var concurrency: Int?
  public var chunkSizeMB: Int?
  public var labels: [Label]
  public var populateCache: Bool

  public init(
    localName: String,
    remoteNames: [String],
    insecure: Bool = false,
    concurrency: Int? = nil,
    chunkSizeMB: Int? = nil,
    labels: [Label] = [],
    populateCache: Bool = false
  ) {
    self.localName = localName
    self.remoteNames = remoteNames
    self.insecure = insecure
    self.concurrency = concurrency
    self.chunkSizeMB = chunkSizeMB
    self.labels = labels
    self.populateCache = populateCache
  }

  public var arguments: [String] {
    var args = ["push", localName]
    args += remoteNames.filter { !$0.isEmpty }
    if insecure { args.append("--insecure") }
    if let concurrency, concurrency != CloneOptions.defaultConcurrency { args += ["--concurrency", String(concurrency)] }
    if let chunkSizeMB, chunkSizeMB > 0 { args += ["--chunk-size", String(chunkSizeMB)] }
    for label in labels where !label.key.isEmpty { args += ["--label", "\(label.key)=\(label.value)"] }
    if populateCache { args.append("--populate-cache") }
    return args
  }
}

// MARK: - prune

public struct PruneOptions: Sendable, Hashable {
  public enum Entries: String, Sendable, Hashable, CaseIterable {
    /// OCI and IPSW caches.
    case caches
    /// Local VMs.
    case vms
  }

  public var entries: Entries
  public var olderThanDays: Int?
  /// Space budget in GiB (least recently used entries beyond it are removed).
  public var spaceBudgetGB: Int?
  /// `--gc` (hidden): garbage-collect broken tags, unreferenced images and orphaned content.
  public var garbageCollect: Bool

  public init(
    entries: Entries = .caches,
    olderThanDays: Int? = nil,
    spaceBudgetGB: Int? = nil,
    garbageCollect: Bool = false
  ) {
    self.entries = entries
    self.olderThanDays = olderThanDays
    self.spaceBudgetGB = spaceBudgetGB
    self.garbageCollect = garbageCollect
  }

  /// Tart refuses to prune without at least one criterion.
  public var hasCriteria: Bool { olderThanDays != nil || spaceBudgetGB != nil || garbageCollect }

  public var arguments: [String] {
    var args = ["prune"]
    if entries != .caches { args += ["--entries", entries.rawValue] }
    if let olderThanDays { args += ["--older-than", String(olderThanDays)] }
    if let spaceBudgetGB { args += ["--space-budget", String(spaceBudgetGB)] }
    if garbageCollect { args.append("--gc") }
    return args
  }
}
