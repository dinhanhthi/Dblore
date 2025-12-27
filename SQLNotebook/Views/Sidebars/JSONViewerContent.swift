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

        FloatingPanelButton(
          icon: isCopied ? "checkmark" : "doc.on.doc",
          helpText: "Copy JSON",
          useSymbolEffect: true,
          action: copyToClipboard
        )
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

    // Show checkmark feedback
    isCopied = true

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
    }
  }
}

#Preview("JSON Viewer") {
  let viewModel = NotebookViewModel()
  let jsonData = """
    {
      "user": {
        "id": 456,
        "name": "Jane Smith",
        "profile": {
          "bio": "Software engineer passionate about databases",
          "location": "San Francisco, CA",
          "website": "https://janesmith.dev"
        },
        "preferences": {
          "theme": "dark",
          "notifications": true,
          "language": "en-US"
        }
      },
      "metadata": {
        "created_at": "2024-01-15T10:30:00Z",
        "updated_at": "2024-03-20T14:45:00Z",
        "version": 3
      },
      "array": [1, 2, 3, 4, 5],
      "object": {
        "key": "value",
        "key2": "value2"
      }
      "null": null,
      "boolean": true,
      "number": 123.45,
      "date": "2024-01-15T10:30:00Z",
      "binary": "SGVsbG8sIFdvcmxkIQ=="
    }
    """
  viewModel.rightSidebarContent = .jsonViewer(json: jsonData, path: "users.details")

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
