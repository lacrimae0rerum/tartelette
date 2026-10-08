import SwiftUI
import TarteletteKit

/// Registry identities Tart can use, from the Keychain, Docker's config and the environment.
struct RegistriesView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SectionCard("Accounts", systemImage: "person.badge.key") {
          Button("Log In…", systemImage: "plus") { model.navigation.present(.login) }
        } content: {
          if model.registries.accounts.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "key.slash")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
              Text("Not Signed In to Any Registry").font(.headline)
              Text("Public images, like the Cirrus Labs ones on ghcr.io, don't need an account. Log in to pull private images or to push your own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
              Button("Log In…") { model.navigation.present(.login) }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(model.registries.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().padding(.leading, 48) }
                AccountRow(account: account)
              }
            }
          }
        }

        SectionCard("How Tart Finds Credentials", systemImage: "list.number") {
          VStack(alignment: .leading, spacing: 10) {
            CredentialSourceRow(
              index: 1, title: "Environment",
              detail: "TART_REGISTRY_USERNAME and TART_REGISTRY_PASSWORD (optionally limited to TART_REGISTRY_HOSTNAME). Set them for Tartelette in Settings › Registries & Network.")
            CredentialSourceRow(
              index: 2, title: "Docker",
              detail: "Entries and credential helpers in ~/.docker/config.json, used as configured by “docker login”.")
            CredentialSourceRow(
              index: 3, title: "Keychain",
              detail: "Accounts saved with “tart login” — what Log In… here does.")
            HStack {
              Spacer()
              Button("Open Settings…") { model.navigation.openSettings() }
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Registries")
    .navigationSubtitle(subtitle)
    .onAppear { model.registries.refresh() }
  }

  private var subtitle: String {
    switch model.registries.accounts.count {
    case 0: "Not signed in"
    case 1: "1 account"
    case let count: "\(count) accounts"
    }
  }
}

private struct AccountRow: View {
  let account: RegistryAccount
  @Environment(AppModel.self) private var model
  @State private var isWorking = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: account.source.systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(account.source.tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(account.host).font(.body.weight(.medium))
        Text(account.username.map { "Signed in as \($0)" } ?? "Credentials configured")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Pill(title: account.source.title, systemImage: account.source.systemImage, tint: account.source.tint)
      if account.source == .keychain {
        if isWorking {
          ProgressView().controlSize(.small)
        } else {
          Button("Log Out") { confirmLogout() }
        }
      }
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }

  private func confirmLogout() {
    let host = account.host
    model.navigation.confirm(
      "Log out of \(host)?",
      message: "Tart removes the saved credentials from your Keychain. Private images from this registry can't be pulled until you log in again.",
      actionTitle: "Log Out"
    ) {
      isWorking = true
      Task {
        defer { isWorking = false }
        do {
          try await model.registries.logout(host)
        } catch {
          model.navigation.show(error: error, title: "Couldn't log out of \(host)")
        }
      }
    }
  }
}

private struct CredentialSourceRow: View {
  let index: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(index)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Color.accentColor, in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension RegistryAccount.Source {
  var title: String {
    switch self {
    case .keychain: "Keychain"
    case .dockerConfig: "Docker"
    case .environment: "Environment"
    }
  }

  var systemImage: String {
    switch self {
    case .keychain: "key.fill"
    case .dockerConfig: "shippingbox.fill"
    case .environment: "terminal.fill"
    }
  }

  var tint: Color {
    switch self {
    case .keychain: .orange
    case .dockerConfig: .blue
    case .environment: .purple
    }
  }
}
