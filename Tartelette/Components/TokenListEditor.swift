import SwiftUI

/// Edits a list of short strings (CIDRs, port mappings, registry names…) as removable tokens.
struct TokenListEditor: View {
  let title: String
  @Binding var tokens: [String]
  var placeholder: String = ""
  /// Returns a problem description for an invalid token, or nil when it is acceptable.
  var validator: (String) -> String? = { _ in nil }

  @State private var draft = ""
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !title.isEmpty {
        Text(title).font(.subheadline.weight(.medium))
      }
      if !tokens.isEmpty {
        TokenFlow(tokens: tokens) { token in
          tokens.removeAll { $0 == token }
        }
      }
      HStack {
        TextField(placeholder, text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button("Add", action: add)
          .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if let problem {
        Text(problem).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private func add() {
    let values = draft
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !values.isEmpty else { return }
    for value in values {
      if let issue = validator(value) {
        problem = issue
        return
      }
    }
    for value in values where !tokens.contains(value) { tokens.append(value) }
    draft = ""
    problem = nil
  }
}

private struct TokenFlow: View {
  let tokens: [String]
  let remove: (String) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) { chips }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
        chips
      }
    }
  }

  @ViewBuilder private var chips: some View {
    ForEach(tokens, id: \.self) { token in
      HStack(spacing: 4) {
        Text(token)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
        Button {
          remove(token)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(token)")
      }
      .padding(.leading, 8)
      .padding(.trailing, 5)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
    }
  }
}
