import AppKit
import SwiftUI
import TarteletteKit
import UniformTypeIdentifiers

/// Creates a VM four ways: clone an OCI image (`tart clone`), install macOS from an IPSW or create
/// an empty Linux VM (`tart create`), or import a `.tvm` archive (`tart import`).
struct NewVMSheet: View {
  let initialTab: NewVMTab
  var imageReference: String? = nil

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var tab: NewVMTab
  @State private var image = ImageForm()
  @State private var mac = MacOSForm()
  @State private var linux = LinuxForm()
  @State private var archive = ImportForm()
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var prepared = false

  init(initialTab: NewVMTab, imageReference: String? = nil) {
    self.initialTab = initialTab
    self.imageReference = imageReference
    _tab = State(initialValue: initialTab)
  }

  var body: some View {
    SheetScaffold(
      title: tab == .importArchive ? "Import Virtual Machine" : "New Virtual Machine",
      subtitle: subtitle,
      systemImage: systemImage,
      commandLine: previewLine,
      primaryTitle: primaryTitle,
      isPrimaryDisabled: command == nil || problem != nil,
      isWorking: isWorking,
      errorMessage: errorMessage,
      onPrimary: submit
    ) {
      Picker("Source", selection: $tab) {
        ForEach(NewVMTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .frame(maxWidth: .infinity)
      .padding(.bottom, 2)

      switch tab {
      case .image: ImageTab(form: $image)
      case .macOS: MacOSTab(form: $mac)
      case .linux: LinuxTab(form: $linux)
      case .importArchive: ImportTab(form: $archive)
      }
    }
    .frame(width: 640, height: sheetHeight)
    .onAppear(perform: prepare)
    .onChange(of: tab) { errorMessage = nil }
    // SwiftUI may reuse this view when another New VM route replaces the presented one.
    .onChange(of: initialTab) { tab = initialTab }
    .onChange(of: imageReference) {
      prepared = false
      prepare()
    }
  }

  // MARK: Derived state

  private var sheetHeight: CGFloat {
    switch tab {
    case .image: 660
    case .macOS: 580
    case .linux: 560
    case .importArchive: 430
    }
  }

  private var subtitle: String {
    switch tab {
    case .image: "Download a ready-made image and create a VM from it."
    case .macOS: "Install macOS from a restore image (IPSW)."
    case .linux: "Create an empty Linux VM and install from an ISO."
    case .importArchive: "Create a VM from a file made with “tart export”."
    }
  }

  private var systemImage: String {
    switch tab {
    case .image: "square.stack.3d.down.right"
    case .macOS: "apple.logo"
    case .linux: "server.rack"
    case .importArchive: "square.and.arrow.down"
    }
  }

  private var primaryTitle: String {
    switch tab {
    case .image: isCached(image.reference) ? "Create" : "Download & Create"
    case .macOS: "Install macOS"
    case .linux: "Create"
    case .importArchive: "Import"
    }
  }

  /// The command to run, or nil while required input is missing.
  private var command: TartCommand? { makeCommand(preview: false) }

  /// The command shown in the preview, with `<placeholders>` for missing input.
  private var previewLine: String? { makeCommand(preview: true)?.previewLine }

  private func makeCommand(preview: Bool) -> TartCommand? {
    func value(_ text: String?, _ placeholder: String) -> String? {
      let trimmed = text?.trimmingCharacters(in: .whitespaces) ?? ""
      if !trimmed.isEmpty { return trimmed }
      return preview ? "<\(placeholder)>" : nil
    }
    switch tab {
    case .image:
      guard let reference = value(image.reference, "image"), let name = value(image.name, "name") else { return nil }
      let overwrite = image.replaceExisting && model.library.vm(named: name) != nil
      var options = image.options(reference: reference, overwrite: overwrite)
      options.newName = name
      return .clone(options)
    case .macOS:
      guard let ipsw = value(mac.ipswArgument, "ipsw"), let name = value(mac.name, "name") else { return nil }
      return .create(CreateOptions(name: name, source: .macOS(ipsw: ipsw), diskSizeGB: mac.diskSizeGB, diskFormat: mac.diskFormat))
    case .linux:
      guard let name = value(linux.name, "name") else { return nil }
      return .create(CreateOptions(name: name, source: .linux, diskSizeGB: linux.diskSizeGB, diskFormat: linux.diskFormat))
    case .importArchive:
      guard let path = value(archive.filePath, "file.tvm"), let name = value(archive.name, "name") else { return nil }
      return .importVM(path: path, name: name)
    }
  }

  /// The first blocking problem of the current tab.
  private var problem: String? {
    switch tab {
    case .image:
      if case .custom = image.choice, let issue = ReferenceValidation.problem(with: image.customReference) { return issue }
      return nameProblem(image.name, replacing: image.replaceExisting)
    case .macOS:
      if mac.source == .url, mac.ipswArgument == nil { return "Enter an http(s) URL of an IPSW file." }
      if mac.source == .file, mac.filePath == nil { return "Choose an IPSW file." }
      return nameProblem(mac.name, replacing: mac.replaceExisting)
    case .linux:
      if let iso = linux.isoPath, iso.hasSuffix("-amd64.iso") {
        return "That ISO targets Intel (amd64). Choose an arm64 installer."
      }
      return nameProblem(linux.name, replacing: linux.replaceExisting)
    case .importArchive:
      if archive.filePath == nil { return "Choose a .tvm file." }
      return nameProblem(archive.name, replacing: archive.replaceExisting)
    }
  }

  private func nameProblem(_ name: String, replacing: Bool) -> String? {
    if let problem = model.library.problemWithNewName(name, allowExisting: replacing) { return problem }
    if replacing, model.library.isRunning(name) { return "Stop “\(name)” before replacing it." }
    return nil
  }

  private func isCached(_ reference: String) -> Bool {
    model.library.images.contains { $0.name == reference }
  }

  // MARK: Actions

  private func prepare() {
    guard !prepared else { return }
    prepared = true
    if let imageReference, !imageReference.isEmpty {
      if ImageCatalog.images.contains(where: { $0.reference == imageReference }) {
        image.choice = .catalog(imageReference)
      } else {
        image.choice = .custom
        image.customReference = imageReference
      }
    }
    image.name = model.library.uniqueName(basedOn: ReferenceValidation.suggestedLocalName(for: image.reference))
    mac.name = model.library.uniqueName(basedOn: "macos")
    linux.name = model.library.uniqueName(basedOn: "linux")
    archive.name = model.library.uniqueName(basedOn: "imported")
  }

  private func submit() {
    guard let command, problem == nil else { return }
    errorMessage = nil
    let library = model.library
    let navigation = model.navigation

    switch tab {
    case .image:
      let name = image.name
      let title = "Get \(image.catalogImage?.displayName ?? image.reference)"
      library.performInBackground(command, title: title) { navigation.show(name) }
      navigation.selection = .activity
      dismiss()
    case .macOS:
      let name = mac.name
      library.performInBackground(command, title: "Install macOS in “\(name)”") { navigation.show(name) }
      navigation.selection = .activity
      dismiss()
    case .importArchive:
      let name = archive.name
      library.performInBackground(command, title: "Import “\(name)”") { navigation.show(name) }
      navigation.selection = .activity
      dismiss()
    case .linux:
      let name = linux.name
      let iso = linux.isoPath
      isWorking = true
      Task {
        defer { isWorking = false }
        do {
          try await library.perform(command, title: "Create “\(name)”")
          if let iso {
            model.profiles.update(name) { profile in
              profile.options.disks.removeAll { $0.location == iso }
              profile.options.disks.append(RunOptions.DiskAttachment(location: iso, readOnly: true))
            }
          }
          navigation.show(name, tab: .overview)
          dismiss()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }
}

// MARK: - Forms

private struct ImageForm {
  enum Choice: Hashable {
    case catalog(String)
    case custom
  }

  var choice: Choice = .catalog(ImageCatalog.recommended.first?.reference ?? ImageCatalog.images[0].reference)
  var customReference = ""
  var name = ""
  var nameEdited = false
  var replaceExisting = false
  var insecure = false
  var concurrency = CloneOptions.defaultConcurrency
  var deduplicate = false
  var stacked = false
  var pruneLimitGB = CloneOptions.defaultPruneLimitGB

  var reference: String {
    switch choice {
    case .catalog(let reference): reference
    case .custom: customReference.trimmingCharacters(in: .whitespaces)
    }
  }

  var catalogImage: CatalogImage? {
    guard case .catalog(let reference) = choice else { return nil }
    return ImageCatalog.images.first { $0.reference == reference }
  }

  func options(reference: String, overwrite: Bool) -> CloneOptions {
    CloneOptions(
      source: reference, newName: name, insecure: insecure, concurrency: concurrency, deduplicate: deduplicate,
      stacked: stacked, overwrite: overwrite, pruneLimitGB: pruneLimitGB)
  }
}

private struct MacOSForm {
  enum Source: String, CaseIterable, Identifiable {
    case latest, file, url
    var id: String { rawValue }
    var title: String {
      switch self {
      case .latest: "Latest macOS supported by this Mac"
      case .file: "IPSW file on this Mac"
      case .url: "IPSW at a URL"
      }
    }
  }

  var source: Source = .latest
  var filePath: String?
  var url = ""
  var name = ""
  var diskSizeGB = CreateOptions.defaultDiskSizeGB
  var diskFormat: DiskFormat = .raw
  var replaceExisting = false

  /// The `--from-ipsw` value, or nil while incomplete.
  var ipswArgument: String? {
    switch source {
    case .latest: return "latest"
    case .file: return filePath
    case .url:
      let value = url.trimmingCharacters(in: .whitespaces)
      guard let parsed = URL(string: value), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
        parsed.host != nil
      else { return nil }
      return value
    }
  }
}

private struct LinuxForm {
  var name = ""
  var diskSizeGB = CreateOptions.defaultDiskSizeGB
  var diskFormat: DiskFormat = .raw
  var isoPath: String?
  var replaceExisting = false
}

private struct ImportForm {
  var filePath: String?
  var name = ""
  var nameEdited = false
  var replaceExisting = false
}

// MARK: - From Image

private struct ImageTab: View {
  @Binding var form: ImageForm
  @Environment(AppModel.self) private var model
  @State private var showsAdvanced = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      List(selection: choiceBinding) {
        Section("macOS") {
          ForEach(ImageCatalog.images.filter { $0.operatingSystem == .macOS }) { image in
            CatalogRow(image: image, isCached: isCached(image.reference))
              .tag(ImageForm.Choice.catalog(image.reference))
          }
        }
        Section("Linux") {
          ForEach(ImageCatalog.images.filter { $0.operatingSystem == .linux }) { image in
            CatalogRow(image: image, isCached: isCached(image.reference))
              .tag(ImageForm.Choice.catalog(image.reference))
          }
        }
        Section("Other") {
          Label("Another image…", systemImage: "link")
            .padding(.vertical, 3)
            .tag(ImageForm.Choice.custom)
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: false))
      .frame(height: 230)
      .accessibilityLabel("Images")

      selectionDetails

      SheetForm {
        SheetFormRow("Name") {
          TextField("VM name", text: nameBinding)
            .textFieldStyle(.roundedBorder)
          NameCollisionControls(name: form.name, replaceExisting: $form.replaceExisting)
        }
      }

      DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
        SheetForm {
          SheetFormRow("Registry") {
            Toggle("Connect over insecure HTTP", isOn: $form.insecure)
          }
          SheetFormRow("Concurrency") {
            NumberStepperField(title: "Concurrency", value: $form.concurrency, range: 1...32, unit: "connections")
          }
          SheetFormRow("Layers") {
            Toggle("Reuse layers from similar cached images", isOn: $form.deduplicate)
            FieldHint("Saves download time and disk space when you already have a related image (--deduplicate).")
          }
          SheetFormRow("Disk") {
            Toggle("Stacked disk on an immutable base", isOn: $form.stacked)
              .disabled(!stackedAvailable)
            FieldHint(
              stackedAvailable
                ? "Keeps the image read-only and writes changes to an overlay (--stacked)."
                : "Stacked disks need macOS 27 and a remote macOS image.")
          }
          SheetFormRow("Auto-prune") {
            NumberStepperField(title: "Prune limit", value: $form.pruneLimitGB, range: 0...4096, step: 10, unit: "GB")
            FieldHint(
              model.settings.disableAutoPrune
                ? "Automatic pruning is turned off in Settings."
                : "If space runs low, Tart may remove up to this much of its cache to fit the image.")
          }
        }
        .padding(.top, 8)
      }
    }
    .onChange(of: form.choice) {
      if form.catalogImage?.operatingSystem != .macOS { form.stacked = false }
      guard !form.nameEdited else { return }
      form.name = model.library.uniqueName(basedOn: ReferenceValidation.suggestedLocalName(for: form.reference))
    }
  }

  @ViewBuilder private var selectionDetails: some View {
    switch form.choice {
    case .catalog:
      if let image = form.catalogImage {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            Text(image.reference)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 0)
          }
          if image.hasGuestAgent {
            SheetNote(
              .info,
              "Sign in as \(CatalogImage.defaultUsername) / \(CatalogImage.defaultPassword). Includes the Tart Guest Agent, so clipboard sync, Console and guest metrics work out of the box.")
          } else {
            SheetNote(
              .warning,
              "Vanilla images have no guest agent: clipboard sync, Console and guest metrics won't work. Sign in as \(CatalogImage.defaultUsername) / \(CatalogImage.defaultPassword).")
          }
        }
      }
    case .custom:
      VStack(alignment: .leading, spacing: 4) {
        TextField("ghcr.io/organization/image:tag", text: $form.customReference)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .onChange(of: form.customReference) {
            guard !form.nameEdited, ReferenceValidation.problem(with: form.customReference) == nil else { return }
            form.name = model.library.uniqueName(basedOn: ReferenceValidation.suggestedLocalName(for: form.reference))
          }
        if !form.customReference.isEmpty {
          ValidationText(message: ReferenceValidation.problem(with: form.customReference))
        }
        FieldHint("Any Tart image in an OCI registry. Private registries need a login (Registries › Log In).")
      }
    }
  }

  private var stackedAvailable: Bool {
    HostOS.supportsStackedDisks && form.catalogImage?.operatingSystem != .linux
      && model.context.capabilities.supports("clone", option: "--stacked")
  }

  private var choiceBinding: Binding<ImageForm.Choice?> {
    Binding(get: { form.choice }, set: { if let value = $0 { form.choice = value } })
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { form.name },
      set: {
        form.name = $0
        form.nameEdited = true
      })
  }

  private func isCached(_ reference: String) -> Bool {
    model.library.images.contains { $0.name == reference }
  }
}

private struct CatalogRow: View {
  let image: CatalogImage
  let isCached: Bool

  var body: some View {
    HStack(spacing: 10) {
      OSIcon(os: image.operatingSystem, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(image.displayName)
        Text(image.flavor.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if isCached {
        Pill(title: "Downloaded", systemImage: "checkmark", tint: .green)
      } else {
        Text("≈ \(image.approximateDownloadGB) GB")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - macOS

private struct MacOSTab: View {
  @Binding var form: MacOSForm
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetForm {
        SheetFormRow("Restore image") {
          Picker("Restore image", selection: $form.source) {
            ForEach(MacOSForm.Source.allCases) { source in
              Text(source.title).tag(source)
            }
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
          switch form.source {
          case .latest:
            FieldHint("Tart asks Apple for the newest macOS this Mac can virtualize and downloads it (about 15 GB).")
          case .file:
            PathPickerField(path: form.filePath, placeholder: "No file chosen") {
              if let url = FilePanels.chooseFile(
                title: "Choose a macOS Restore Image", contentTypes: [.ipsw],
                directoryURL: URL.downloadsDirectory)
              {
                form.filePath = url.path
              }
            }
          case .url:
            TextField("https://updates.cdn-apple.com/…/UniversalMac_…_Restore.ipsw", text: $form.url)
              .textFieldStyle(.roundedBorder)
            if !form.url.isEmpty, form.ipswArgument == nil {
              ValidationText(message: "Enter an http(s) URL.")
            }
          }
        }
        SheetFormRow("Name") {
          TextField("VM name", text: $form.name)
            .textFieldStyle(.roundedBorder)
          NameCollisionControls(name: form.name, replaceExisting: $form.replaceExisting)
        }
        DiskRows(sizeGB: $form.diskSizeGB, format: $form.diskFormat)
      }
      SheetNote(
        .info,
        "Installation takes a while. Afterwards, start the VM and finish Setup Assistant in its window — creating an “admin” account with password “admin” matches the Cirrus Labs images.")
    }
  }
}

// MARK: - Linux

private struct LinuxTab: View {
  @Binding var form: LinuxForm

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetForm {
        SheetFormRow("Name") {
          TextField("VM name", text: $form.name)
            .textFieldStyle(.roundedBorder)
          NameCollisionControls(name: form.name, replaceExisting: $form.replaceExisting)
        }
        DiskRows(sizeGB: $form.diskSizeGB, format: $form.diskFormat)
        SheetFormRow("Installer") {
          PathPickerField(
            path: form.isoPath, placeholder: "No ISO attached",
            choose: {
              if let url = FilePanels.chooseFile(
                title: "Choose an arm64 Installer ISO", contentTypes: [.isoImage, .diskImage],
                directoryURL: URL.downloadsDirectory)
              {
                form.isoPath = url.path
              }
            },
            clear: { form.isoPath = nil })
          FieldHint("Attached read-only on every start (--disk <iso>:ro). Remove it in Run Options once the OS is installed.")
        }
      }
      SheetNote(
        .info,
        "The VM gets 4 CPUs, 4 GB of memory and an empty disk. Ready-made Ubuntu, Debian and Fedora images are on the From Image tab.")
    }
  }
}

// MARK: - Import

private struct ImportTab: View {
  @Binding var form: ImportForm
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetForm {
        SheetFormRow("Archive") {
          PathPickerField(path: form.filePath, placeholder: "No file chosen") {
            if let url = FilePanels.chooseFile(
              title: "Choose a Tart Archive", message: "Choose a .tvm file created with “tart export”.",
              contentTypes: [.tartArchive], directoryURL: URL.downloadsDirectory)
            {
              form.filePath = url.path
              if !form.nameEdited {
                form.name = model.library.uniqueName(basedOn: url.deletingPathExtension().lastPathComponent)
              }
            }
          }
        }
        SheetFormRow("Name") {
          TextField("VM name", text: nameBinding)
            .textFieldStyle(.roundedBorder)
          NameCollisionControls(name: form.name, replaceExisting: $form.replaceExisting)
        }
      }
      SheetNote(.info, "Importing decompresses the archive into a new VM. The VM gets a new MAC address if another VM already uses its address.")
    }
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { form.name },
      set: {
        form.name = $0
        form.nameEdited = true
      })
  }
}

// MARK: - Shared rows

/// Disk size and format rows for `tart create`.
private struct DiskRows: View {
  @Binding var sizeGB: Int
  @Binding var format: DiskFormat

  var body: some View {
    SheetFormRow("Disk size") {
      NumberStepperField(title: "Disk size", value: $sizeGB, range: 10...4096, step: 10, unit: "GB")
      FieldHint("Space is allocated as the guest writes data. You can grow the disk later, but not shrink it.")
    }
    SheetFormRow("Disk format") {
      Picker("Disk format", selection: $format) {
        Text("Raw").tag(DiskFormat.raw)
        Text("ASIF").tag(DiskFormat.asif)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .disabled(!HostOS.supportsASIF)
      FieldHint(
        HostOS.supportsASIF
          ? "ASIF (Apple Sparse Image Format) is faster but needs macOS 26 to run the VM."
          : "ASIF needs macOS 26 Tahoe or later.")
    }
  }
}

/// Explains a name collision and offers to replace the existing VM.
private struct NameCollisionControls: View {
  let name: String
  @Binding var replaceExisting: Bool
  @Environment(AppModel.self) private var model

  var body: some View {
    if let problem = VMNameValidation.problem(with: name) {
      ValidationText(message: problem)
    } else if model.library.vm(named: name) != nil {
      VStack(alignment: .leading, spacing: 4) {
        if model.library.isRunning(name) {
          ValidationText(message: "“\(name)” exists and is running. Choose another name.")
        } else {
          ValidationText(message: replaceExisting ? nil : "A VM named “\(name)” already exists.")
          Toggle("Replace the existing VM (its disk will be erased)", isOn: $replaceExisting)
            .toggleStyle(.checkbox)
        }
      }
    }
  }
}
