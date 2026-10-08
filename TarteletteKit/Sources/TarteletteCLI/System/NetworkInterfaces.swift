import Foundation
import SystemConfiguration
import TarteletteCore

/// Host network interfaces that can back `tart run --net-bridged`.
public enum NetworkInterfaces {
  /// Ethernet, Wi-Fi, Thunderbolt bridge and bond interfaces, sorted by BSD name.
  ///
  /// Tart accepts either the BSD name (`en0`) or the display name (`Wi-Fi`) for `--net-bridged`.
  public static func bridgeable() -> [BridgedInterface] {
    guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
    let allowedTypes: Set<String> = [
      kSCNetworkInterfaceTypeEthernet as String,
      kSCNetworkInterfaceTypeIEEE80211 as String,
      "Bridge",
      kSCNetworkInterfaceTypeBond as String,
    ]

    var seen = Set<String>()
    var interfaces: [BridgedInterface] = []
    for interface in all {
      guard let type = SCNetworkInterfaceGetInterfaceType(interface) as String?, allowedTypes.contains(type),
        let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?, !bsdName.isEmpty,
        seen.insert(bsdName).inserted
      else { continue }
      let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
      interfaces.append(BridgedInterface(bsdName: bsdName, displayName: displayName))
    }
    return interfaces.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
  }
}
