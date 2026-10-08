import SwiftUI

/// The standard layout for operation sheets: header, form content, command preview, and a
/// Cancel/primary button bar. Keeps every sheet consistent.
///
/// ```swift
/// SheetScaffold(title: "Rename VM", systemImage: "pencil", commandLine: command.commandLine,
///               primaryTitle: "Rename", isPrimaryDisabled: !isValid, isWorking: isWorking,
///               onPrimary: rename) {
///   TextField("Name", text: $name)
/// }
/// ```
struct SheetScaffold<Content: View>: View {
  let title: String
  var subtitle: String?
  var systemImage: String = "shippingbox"
  var commandLine: String?
  var primaryTitle: String
  var primaryRole: ButtonRole?
  var isPrimaryDisabled = false
  var isWorking = false
  /// Shown above the buttons in red, e.g. the last error.
  var errorMessage: String?
  var onPrimary: () -> Void
  @ViewBuilder var content: () -> Content

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(Color.accentColor)
          .frame(width: 40, height: 40)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.title3.weight(.semibold))
          if let subtitle {
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 12)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)

      VStack(spacing: 10) {
        if let commandLine {
          CommandPreview(commandLine: commandLine)
        }
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        HStack {
          if isWorking {
            ProgressView().controlSize(.small)
          }
          Spacer()
          Button("Cancel", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button(primaryTitle, role: primaryRole, action: onPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isPrimaryDisabled || isWorking)
        }
      }
      .padding(20)
      .background(.bar)
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 300)
  }
}
