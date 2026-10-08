import AppKit
import SwiftUI
import TarteletteKit
import UniformTypeIdentifiers

// Building blocks shared by the operation sheets: an aligned two-column form, inline notes,
// file panels and validation of Tart names and OCI references.

/// A macOS-style form: trailing-aligned labels in the first column, controls in the second.
struct SheetForm<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One labelled row of a `SheetForm`. An empty label leaves the first column blank.
struct SheetFormRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content

  init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
    self.label = label
    self.content = content
  }

  var body: some View {
    GridRow {
      Text(label.isEmpty ? "" : "\(label):")
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
        .accessibilityHidden(label.isEmpty)
      VStack(alignment: .leading, spacing: 4) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Secondary explanatory text under a control.
struct FieldHint: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A coloured callout for warnings and notes inside sheets.
struct SheetNote: View {
  enum Kind {
    case info, warning, danger

    var tint: Color {
      switch self {
      case .info: .blue
      case .warning: .orange
      case .danger: .red
      }
    }

    var systemImage: String {
      switch self {
      case .info: "info.circle.fill"
      case .warning: "exclamationmark.triangle.fill"
      case .danger: "exclamationmark.octagon.fill"
      }
    }
  }

  let kind: Kind
  let text: String
  var title: String?

  init(_ kind: Kind, _ text: String, title: String? = nil) {
    self.kind = kind
    self.text = text
    self.title = title
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: kind.systemImage)
        .foregroundStyle(kind.tint)
      VStack(alignment: .leading, spacing: 2) {
        if let title {
          Text(title).font(.callout.weight(.semibold))
        }
        Text(text)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A red inline validation message (only rendered when there is a problem).
struct ValidationText: View {
  let message: String?

  var body: some View {
    if let message {
      Label(message, systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A whole-number text field with a stepper, clamped to `range`.
struct NumberStepperField: View {
  let title: String
  @Binding var value: Int
  let range: ClosedRange<Int>
  var step = 1
  var unit: String?

  var body: some View {
    HStack(spacing: 6) {
      TextField(title, value: $value, format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 72)
        .labelsHidden()
        .onChange(of: value) { _, newValue in
          let clamped = min(max(newValue, range.lowerBound), range.upperBound)
          if clamped != newValue { value = clamped }
        }
      Stepper(title, value: $value, in: range, step: step)
        .labelsHidden()
      if let unit {
        Text(unit).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue(unit.map { "\(value) \($0)" } ?? "\(value)")
  }
}

/// A read-only path display with a Choose… button.
struct PathPickerField: View {
  let path: String?
  var placeholder = "None"
  var buttonTitle = "Choose…"
  let choose: () -> Void
  var clear: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if let path, !path.isEmpty {
          Text((path as NSString).abbreviatingWithTildeInPath)
            .truncationMode(.middle)
            .help(path)
        } else {
          Text(placeholder).foregroundStyle(.tertiary)
        }
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      if let clear, path?.isEmpty == false {
        Button(action: clear) {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Clear")
      }
      Button(buttonTitle, action: choose)
    }
  }
}

// MARK: - File panels

/// App-modal open and save panels (they work from inside SwiftUI sheets).
enum FilePanels {
  static func chooseFile(
    title: String, message: String? = nil, contentTypes: [UTType] = [], directoryURL: URL? = nil
  ) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message ?? ""
    panel.prompt = "Choose"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
    panel.directoryURL = directoryURL
    return panel.runModal() == .OK ? panel.url : nil
  }

  static func saveFile(title: String, suggestedName: String, contentTypes: [UTType], directoryURL: URL?) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.prompt = "Choose"
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = contentTypes
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.directoryURL = directoryURL
    return panel.runModal() == .OK ? panel.url : nil
  }
}

extension UTType {
  /// Tart's export format (`tart export`): an LZFSE-compressed Apple Archive.
  static let tartArchive = UTType(filenameExtension: "tvm", conformingTo: .data) ?? .data
  static let ipsw = UTType(filenameExtension: "ipsw", conformingTo: .data) ?? .data
  static let isoImage = UTType(filenameExtension: "iso", conformingTo: .diskImage) ?? .diskImage
}

// MARK: - Command preview

extension TartCommand {
  /// The command line for previews: values still missing are written as `<placeholder>`
  /// (unquoted), so the preview reads like documentation until the form is complete.
  var previewLine: String {
    commandLine
      .replacingOccurrences(of: "'<", with: "<")
      .replacingOccurrences(of: ">'", with: ">")
  }
}

/// Returns `value`, or `<placeholder>` when it is blank.
nonisolated func previewValue(_ value: String, _ placeholder: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespaces)
  return trimmed.isEmpty ? "<\(placeholder)>" : trimmed
}

// MARK: - Validation

/// Validation of OCI references in Tart's grammar: `host[:port]/namespace[:tag | @sha256:<hex>]`.
nonisolated enum ReferenceValidation {
  static func problem(with reference: String) -> String? {
    let value = reference.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return "Enter an image reference." }
    if value.contains("://") { return "Leave out the scheme — use “ghcr.io/org/image:tag”." }
    if value.contains(where: \.isWhitespace) { return "References can't contain spaces." }
    guard let slash = value.firstIndex(of: "/") else {
      return "Include the registry host, e.g. “ghcr.io/org/image:tag”."
    }
    let host = value[..<slash]
    if host.isEmpty || !(host.contains(".") || host.contains(":") || host == "localhost") {
      return "“\(host)” doesn't look like a registry host."
    }
    let remainder = value[value.index(after: slash)...]
    if remainder.isEmpty || remainder.hasPrefix("/") || remainder.hasPrefix(":") || remainder.hasPrefix("@") {
      return "Add a repository after the host."
    }
    if let at = remainder.firstIndex(of: "@") {
      let digest = remainder[remainder.index(after: at)...]
      if !digest.hasPrefix("sha256:") || digest.count != 71 { return "Digests look like “@sha256:” plus 64 hex characters." }
    }
    return nil
  }

  static func isRemote(_ name: String) -> Bool { problem(with: name) == nil }

  /// A friendly local name derived from a reference: `ghcr.io/cirruslabs/macos-tahoe-base:latest` → `macos-tahoe-base`.
  static func suggestedLocalName(for reference: String) -> String {
    var last = reference.split(separator: "/").last.map(String.init) ?? reference
    if let at = last.firstIndex(of: "@") { last = String(last[..<at]) }
    var name = last
    var tag: String?
    if let colon = last.lastIndex(of: ":") {
      name = String(last[..<colon])
      tag = String(last[last.index(after: colon)...])
    }
    if let tag, !tag.isEmpty, tag != "latest" { name += "-" + tag }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    return cleaned.isEmpty ? "vm" : cleaned
  }
}

extension VMLibrary {
  /// A name based on `base` that no local VM uses yet (`base`, `base-2`, `base-3`…).
  func uniqueName(basedOn base: String) -> String {
    let taken = Set(vms.map(\.name))
    guard taken.contains(base) else { return base }
    var index = 2
    while taken.contains("\(base)-\(index)") { index += 1 }
    return "\(base)-\(index)"
  }

  /// Problem with a new local VM name, or nil. `allowExisting` permits replacing a VM.
  func problemWithNewName(_ name: String, allowExisting: Bool = false) -> String? {
    if let problem = VMNameValidation.problem(with: name) { return problem }
    if !allowExisting, vm(named: name) != nil { return "A VM named “\(name)” already exists." }
    return nil
  }
}

extension CatalogImage.Flavor {
  var title: String {
    switch self {
    case .vanilla: "Vanilla"
    case .base: "Base"
    case .xcode: "Xcode"
    case .server: "Server"
    }
  }
}

/// Host OS checks for features that need newer macOS releases.
nonisolated enum HostOS {
  static func isAtLeast(_ major: Int) -> Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0))
  }

  /// ASIF disk images need macOS 26 Tahoe.
  static var supportsASIF: Bool { isAtLeast(26) }
  /// Stacked disks need macOS 27.
  static var supportsStackedDisks: Bool { isAtLeast(27) }
}
