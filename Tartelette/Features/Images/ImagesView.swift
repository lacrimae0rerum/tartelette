import AppKit
import SwiftUI
import TarteletteKit

/// The local OCI image cache (`tart list --source oci`) and the Cirrus Labs catalog.
struct ImagesView: View {
  @Environment(AppModel.self) private var model
  @State private var showsDigests = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SectionCard("Downloaded", systemImage: "square.stack.3d.up") {
          HStack(spacing: 12) {
            if hasDigestEntries {
              Toggle("Show digests", isOn: $showsDigests)
                .toggleStyle(.checkbox)
                .help("Tart lists each pulled image by tag and by content digest")
            }
            Button("Pull Image…", systemImage: "icloud.and.arrow.down") { model.navigation.present(.pull) }
          }
        } content: {
          if visibleImages.isEmpty {
            emptyState
          } else {
            VStack(spacing: 0) {
              ForEach(Array(visibleImages.enumerated()), id: \.element.id) { index, image in
                if index > 0 { Divider().padding(.leading, 48) }
                ImageRow(image: image)
              }
            }
          }
        }

        SectionCard("Cirrus Labs Images", systemImage: "sparkles") {
          Text("Sign in as \(CatalogImage.defaultUsername) / \(CatalogImage.defaultPassword)")
            .font(.caption)
            .foregroundStyle(.secondary)
        } content: {
          CatalogGrid()
        }
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Images")
    .navigationSubtitle(subtitle)
  }

  private var cachedImages: [VMListing] {
    model.library.images.filter { showsDigests || !$0.name.contains("@sha256:") || !hasTagEntries }
  }

  private var visibleImages: [VMListing] {
    let query = model.navigation.searchText.trimmingCharacters(in: .whitespaces)
    let images = cachedImages
    guard !query.isEmpty else { return images }
    return images.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private var hasDigestEntries: Bool { model.library.images.contains { $0.name.contains("@sha256:") } }
  private var hasTagEntries: Bool { model.library.images.contains { !$0.name.contains("@sha256:") } }

  private var subtitle: String {
    let images = model.library.images.filter { !$0.name.contains("@sha256:") }
    let count = images.isEmpty ? model.library.images.count : images.count
    guard count > 0 else { return "No downloaded images" }
    let bytes = model.metrics.storage?.ociCacheBytes
    let size = bytes.map { " · \(Formatting.bytes($0))" } ?? ""
    return (count == 1 ? "1 image" : "\(count) images") + size
  }

  @ViewBuilder private var emptyState: some View {
    if model.library.images.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "square.stack.3d.up.slash")
          .font(.system(size: 30))
          .foregroundStyle(.tertiary)
        Text("No Downloaded Images").font(.headline)
        Text("Images you pull or clone from a registry are cached here, so new VMs from them are created in seconds.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
    } else {
      Text("No images match “\(model.navigation.searchText)”.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
  }
}

/// One cached image with its actions.
private struct ImageRow: View {
  let image: VMListing
  @Environment(AppModel.self) private var model
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "shippingbox.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(
          LinearGradient(colors: [.teal, .blue], startPoint: .top, endPoint: .bottom),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(friendlyName).font(.body.weight(.medium))
          if isDigest {
            Pill(title: "Digest", tint: .secondary)
          } else if let tag {
            Pill(title: tag, systemImage: "tag", tint: .accentColor)
          }
        }
        Text(image.name)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Text(metadata)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 12)

      Button("New VM…") { model.navigation.present(.clone(source: image.name)) }
        .help("Create a VM from this image")
      Menu {
        ImageActions(image: image)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("More actions for \(friendlyName)")
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
    .background(isHovering ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
    .onHover { isHovering = $0 }
    .contextMenu { ImageActions(image: image) }
  }

  private var isDigest: Bool { image.name.contains("@sha256:") }

  private var friendlyName: String {
    var last = image.name.split(separator: "/").last.map(String.init) ?? image.name
    if let at = last.firstIndex(of: "@") { last = String(last[..<at]) }
    if let colon = last.lastIndex(of: ":") { last = String(last[..<colon]) }
    return last
  }

  private var tag: String? {
    guard !isDigest, let last = image.name.split(separator: "/").last, let colon = last.lastIndex(of: ":") else {
      return nil
    }
    return String(last[last.index(after: colon)...])
  }

  private var metadata: String {
    var parts: [String] = []
    if let disk = image.diskGB { parts.append("\(Formatting.gigabytes(disk)) disk") }
    if let size = image.sizeGB { parts.append("\(Formatting.gigabytes(size)) on this Mac") }
    parts.append("used \(Formatting.relative(image.lastAccessed).lowercased())")
    return parts.joined(separator: " · ")
  }
}

/// Actions for a cached image, shared by the row menu and the context menu.
private struct ImageActions: View {
  let image: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    Button("New VM from Image…", systemImage: "plus.square.on.square") {
      model.navigation.present(.clone(source: image.name))
    }
    Button("Push / Retag…", systemImage: "icloud.and.arrow.up") {
      model.navigation.present(.push(vm: image.name))
    }
    Button("Export…", systemImage: "square.and.arrow.up") {
      model.navigation.present(.exportVM(vm: image.name))
    }
    Divider()
    Button("Copy Reference", systemImage: "doc.on.doc") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(image.name, forType: .string)
    }
    Button("Copy Digest Reference", systemImage: "number") {
      Task { await resolveDigest() }
    }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive) {
      model.navigation.present(.confirmDelete(names: [image.name]))
    }
  }

  /// `tart fqn` resolves a tag to `host/namespace@sha256:…` from the local cache.
  private func resolveDigest() async {
    guard let client = model.context.client else { return }
    do {
      let output = try await client.execute(.fqn(name: image.name), timeout: .seconds(20))
      let digest = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(digest, forType: .string)
      model.navigation.show(title: "Digest Reference Copied", message: digest)
    } catch {
      model.navigation.show(error: error, title: "Couldn't resolve the digest")
    }
  }
}

/// The Cirrus Labs catalog as cards. “Get” creates a VM; the context menu offers a plain pull.
private struct CatalogGrid: View {
  @Environment(AppModel.self) private var model
  @State private var platform: VMOperatingSystem = .macOS

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Platform", selection: $platform) {
        Text("macOS").tag(VMOperatingSystem.macOS)
        Text("Linux").tag(VMOperatingSystem.linux)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12)], spacing: 12) {
        ForEach(ImageCatalog.images.filter { $0.operatingSystem == platform }) { image in
          CatalogCard(image: image) {
            model.navigation.present(.newVM(initialTab: .image, imageReference: image.reference))
          }
          .contextMenu {
            Button("New VM from Image…") {
              model.navigation.present(.newVM(initialTab: .image, imageReference: image.reference))
            }
            Button("Download Only") {
              model.library.performInBackground(.pull(PullOptions(remoteName: image.reference)), title: "Pull \(image.displayName)")
              model.navigation.selection = .activity
            }
            Divider()
            Button("Copy Reference") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(image.reference, forType: .string)
            }
          }
        }
      }
    }
  }
}
