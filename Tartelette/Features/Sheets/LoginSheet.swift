import SwiftUI
import TarteletteKit

/// `tart login <host> --username <user> --password-stdin`. The password only travels over the
/// child's standard input; Tart stores it in the login Keychain.
struct LoginSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var host = "ghcr.io"
  @State private var username = ""
  @State private var password = ""
  @State private var insecure = false
  @State private var noValidate = false
  @State private var isWorking = false
  @State private var errorMessage: String?
  @FocusState private var focus: Field?

  private enum Field { case host, username, password }

  var body: some View {
    SheetScaffold(
      title: "Log In to a Registry",
      subtitle: "Tart saves the credentials in your login Keychain.",
      systemImage: "key",
      commandLine: TartCommand.login(previewOptions).previewLine,
      primaryTitle: "Log In",
      isPrimaryDisabled: problem != nil,
      isWorking: isWorking,
      errorMessage: errorMessage,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("Registry") {
          TextField("ghcr.io", text: $host)
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .host)
          if !host.isEmpty { ValidationText(message: hostProblem) }
        }
        SheetFormRow("Username") {
          TextField("Username", text: $username)
            .textFieldStyle(.roundedBorder)
            .textContentType(.username)
            .focused($focus, equals: .username)
        }
        SheetFormRow("Password") {
          SecureField(passwordPrompt, text: $password)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .focused($focus, equals: .password)
          FieldHint(passwordHint)
        }
        SheetFormRow("Options") {
          Toggle("Connect over insecure HTTP", isOn: $insecure)
          Toggle("Save without checking the credentials", isOn: $noValidate)
        }
      }
      SheetNote(.info, "The password is passed to Tart through standard input — it never appears in the command line or in Activity.")
    }
    .frame(width: 540, height: 450)
    .onAppear { focus = .username }
  }

  private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

  private var options: LoginOptions {
    LoginOptions(
      host: trimmedHost, username: username.trimmingCharacters(in: .whitespaces), insecure: insecure,
      noValidate: noValidate)
  }

  private var previewOptions: LoginOptions {
    var preview = options
    preview.host = previewValue(preview.host, "registry")
    preview.username = previewValue(preview.username, "username")
    return preview
  }

  private var hostProblem: String? {
    if trimmedHost.isEmpty { return "Enter the registry host." }
    if trimmedHost.contains("://") { return "Leave out the scheme — just the host, like “ghcr.io”." }
    if trimmedHost.contains("/") || trimmedHost.contains(where: \.isWhitespace) {
      return "Enter only the host name (and port), like “registry.example.com:5000”."
    }
    return nil
  }

  private var problem: String? {
    if let hostProblem { return hostProblem }
    if options.username.isEmpty { return "Enter your username." }
    if password.isEmpty { return "Enter your password or token." }
    return nil
  }

  private var passwordPrompt: String { trimmedHost.hasSuffix("ghcr.io") ? "Personal access token" : "Password or token" }

  private var passwordHint: String {
    switch trimmedHost {
    case "ghcr.io": "Use a GitHub personal access token with the read:packages (and write:packages to push) scope."
    case let value where value.hasSuffix(".amazonaws.com"): "Use the output of “aws ecr get-login-password” with the user AWS."
    case let value where value.hasSuffix("pkg.dev") || value == "gcr.io": "Use “oauth2accesstoken” with a gcloud access token, or a JSON key with “_json_key”."
    default: "Most registries accept an access token instead of your account password."
    }
  }

  private func submit() {
    guard problem == nil else { return }
    isWorking = true
    errorMessage = nil
    let options = options
    let secret = password
    Task {
      defer { isWorking = false }
      do {
        try await model.registries.login(options, password: secret)
        password = ""
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
