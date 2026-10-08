import Foundation

/// Well-known Tart images published by Cirrus Labs (ghcr.io/cirruslabs).
public struct CatalogImage: Sendable, Hashable, Identifiable {
  public enum Flavor: String, Sendable, Hashable, CaseIterable {
    /// Plain OS install. No guest agent: no `tart exec`, clipboard bridge or agent IP resolution.
    case vanilla
    /// Vanilla plus Homebrew, common tools and the Tart Guest Agent.
    case base
    /// Base plus the latest Xcode and simulators.
    case xcode
    /// Linux server image with the Tart Guest Agent.
    case server

    public var summary: String {
      switch self {
      case .vanilla: "Clean install, no guest agent"
      case .base: "Homebrew, tools and guest agent"
      case .xcode: "Base plus Xcode and simulators"
      case .server: "Server image with guest agent"
      }
    }
  }

  public var id: String { reference }
  public var displayName: String
  public var reference: String
  public var operatingSystem: VMOperatingSystem
  public var flavor: Flavor
  /// Rough compressed download size, shown as a hint.
  public var approximateDownloadGB: Int

  public init(
    displayName: String,
    reference: String,
    operatingSystem: VMOperatingSystem,
    flavor: Flavor,
    approximateDownloadGB: Int
  ) {
    self.displayName = displayName
    self.reference = reference
    self.operatingSystem = operatingSystem
    self.flavor = flavor
    self.approximateDownloadGB = approximateDownloadGB
  }

  /// Whether the image ships the Tart Guest Agent (enables exec, metrics and the clipboard bridge).
  public var hasGuestAgent: Bool { flavor != .vanilla }

  /// Default credentials for Cirrus Labs images (GUI, console and SSH).
  public static let defaultUsername = "admin"
  public static let defaultPassword = "admin"
}

public enum ImageCatalog {
  private static let macOSReleases: [(slug: String, name: String)] = [
    ("tahoe", "macOS Tahoe"),
    ("sequoia", "macOS Sequoia"),
    ("sonoma", "macOS Sonoma"),
    ("ventura", "macOS Ventura"),
    ("monterey", "macOS Monterey"),
  ]

  public static let images: [CatalogImage] = {
    var images: [CatalogImage] = []
    for release in macOSReleases {
      for flavor in [CatalogImage.Flavor.base, .xcode, .vanilla] {
        let suffix =
          switch flavor {
          case .base: ""
          case .xcode: " with Xcode"
          case .vanilla: " (Vanilla)"
          case .server: ""
          }
        images.append(
          CatalogImage(
            displayName: release.name + suffix,
            reference: "ghcr.io/cirruslabs/macos-\(release.slug)-\(flavor.rawValue):latest",
            operatingSystem: .macOS,
            flavor: flavor,
            approximateDownloadGB: flavor == .xcode ? 60 : (flavor == .base ? 30 : 25)
          ))
      }
    }
    for (slug, name) in [("ubuntu", "Ubuntu"), ("debian", "Debian"), ("fedora", "Fedora")] {
      images.append(
        CatalogImage(
          displayName: name,
          reference: "ghcr.io/cirruslabs/\(slug):latest",
          operatingSystem: .linux,
          flavor: .server,
          approximateDownloadGB: 2
        ))
    }
    return images
  }()

  public static var recommended: [CatalogImage] {
    images.filter { image in
      image.reference.contains("tahoe-base") || image.reference.contains("sequoia-xcode")
        || image.reference.contains("/ubuntu:")
    }
  }
}

/// Limits that the UI warns about before starting VMs.
public enum VirtualizationLimits {
  /// Apple's licence and Virtualization.framework allow two concurrent macOS guests per host.
  public static let maximumConcurrentMacOSGuests = 2
}
