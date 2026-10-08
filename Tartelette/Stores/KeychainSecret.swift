import Foundation
import Security

/// A single secret stored as a generic password in the login Keychain.
nonisolated struct KeychainSecret: Sendable {
  let service: String
  var account = "default"

  func read() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  /// Stores `value`, or deletes the item when `value` is nil or empty.
  @discardableResult
  func write(_ value: String?) -> Bool {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    guard let value, !value.isEmpty else {
      let status = SecItemDelete(base as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }
    let data = Data(value.utf8)
    let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return true }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = "Tartelette"
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }
}
