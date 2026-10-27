//
//  JSONViewerContent.swift
//  Dblore
//

import SwiftUI

// MARK: - JSON Viewer

struct JSONViewerContent: View {
  let json: String
  let path: String
  let onSave: ((String) -> Void)?

  @State private var isPrettyPrinted = true
  @State private var searchText = ""
  @State private var isCopied = false
  @State private var isEditing = false
  @State private var editedJSON: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Fixed header: Path info and Toolbar
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Path info
        Text(path)
          .font(.caption)
          .foregroundColor(.foregroundMuted)

        // Toolbar
        HStack {
          if !isEditing {
            Toggle("Pretty Print", isOn: $isPrettyPrinted)
              .toggleStyle(.switch)
              .tint(.accent)
              .controlSize(.mini)
          }

          Spacer()

          if isEditing {
            // Cancel and Save icon buttons
            FloatingPanelButton(
              icon: "xmark",
              helpText: "Cancel",
              useSymbolEffect: false,
              action: cancelEdit
            )

            FloatingPanelButton(
              icon: "checkmark",
              helpText: "Save",
              useSymbolEffect: false,
              action: saveEdit
            )
          } else {
            // Edit and Copy buttons
            FloatingPanelButton(
              icon: "pencil",
              helpText: "Edit JSON",
              useSymbolEffect: false,
              action: startEdit
            )

            FloatingPanelButton(
              icon: isCopied ? "checkmark" : "doc.on.doc",
              helpText: "Copy JSON",
              useSymbolEffect: true,
              action: copyToClipboard
            )
          }
        }
      }
      .padding(.bottom, Spacing.md)

      // JSON content - scrollable both vertically and horizontally
      if isEditing {
        PlainTextEditor(text: $editedJSON)
          .background(Color.inputBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          .frame(maxHeight: .infinity)
      } else {
        // Nested ScrollViews for both axes to avoid centering issue
        // Horizontal outside so scrollbar is always visible at bottom
        ScrollView(.horizontal, showsIndicators: true) {
          ScrollView(.vertical, showsIndicators: true) {
            HighlightedJSONText(json: formattedJSON, cachesAnySize: true)
              .padding(Spacing.sm)
          }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
    }
    .onDisappear(perform: Self.clearCaches)
  }

  /// Last pretty-printed JSON and its output: the body re-runs on every state change (copy
  /// feedback, edit) and on parent re-renders with the same JSON
  static var lastPrettyPrint: (json: String, pretty: String)?

  private var formattedJSON: String {
    isPrettyPrinted ? Self.prettyPrinted(json) : json
  }

  /// `json` pretty-printed, or unchanged when it does not parse or its pretty form is too large
  /// to highlight (deep nesting indents every element). Cached at any size until the viewer
  /// closes.
  static func prettyPrinted(_ json: String) -> String {
    if let last = lastPrettyPrint, last.json == json { return last.pretty }
    var pretty = json
    if case .formatted(let text, _) = CellInfoContent.prettyPrintedJSON(
      json, maxOutputBytes: CellInfoContent.maxHighlightedPrettyBytes)
    {
      pretty = text
    }
    lastPrettyPrint = (json, pretty)
    return pretty
  }

  /// Drops the cached JSON, its pretty copy and highlighted text (the viewer closed)
  static func clearCaches() {
    lastPrettyPrint = nil
    HighlightedJSONText.lastHighlight = nil
  }

  private func startEdit() {
    editedJSON = formattedJSON
    isEditing = true
  }

  private func cancelEdit() {
    isEditing = false
    editedJSON = ""
  }

  private func saveEdit() {
    onSave?(editedJSON)
    isEditing = false
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

#Preview("Big JSON") {
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
      },
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

#Preview("Short JSON") {
  let viewModel = NotebookViewModel()
  let jsonData = """
    {
      "screen" : "15.6 inch",
      "ram" : "16GB",
      "storage" : "512GB SSD",
      "cpu" : "Intel i7"
    }
    """
  viewModel.rightSidebarContent = .jsonViewer(
    json: jsonData, path: "Row 1, Column 'specifications'")

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
