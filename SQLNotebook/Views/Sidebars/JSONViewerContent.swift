//
//  JSONViewerContent.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - JSON Viewer

struct JSONViewerContent: View {
  let json: String
  let path: String
  @State private var isPrettyPrinted = true
  @State private var searchText = ""
  @State private var isCopied = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Path info
      Text(path)
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      // Toolbar
      HStack {
        Toggle("Pretty Print", isOn: $isPrettyPrinted)
          .toggleStyle(.switch)
          .controlSize(.mini)

        Spacer()

        Button(action: copyToClipboard) {
          Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
            .frame(width: 70, height: 20, alignment: .leading)
        }
        .buttonStyle(GhostButtonStyle())
        .animation(.easeInOut(duration: 0.1), value: isCopied)
      }

      // JSON content with syntax highlighting
      ScrollView(.horizontal, showsIndicators: false) {
        HighlightedJSONText(json: formattedJSON)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(Spacing.sm)
      .background(Color.cellBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
  }

  private var formattedJSON: String {
    if isPrettyPrinted {
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let prettyData = try? JSONSerialization.data(
          withJSONObject: object, options: .prettyPrinted),
        let prettyString = String(data: prettyData, encoding: .utf8)
      else {
        return json
      }
      return prettyString
    }
    return json
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(formattedJSON, forType: .string)

    isCopied = true
    Task {
      try? await Task.sleep(for: .milliseconds(1000))
      await MainActor.run {
        isCopied = false
      }
    }
  }
}
