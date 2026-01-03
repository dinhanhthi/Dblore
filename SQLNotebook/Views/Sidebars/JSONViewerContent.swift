//
//  JSONViewerContent.swift
//  SQLNotebook
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
        TextEditor(text: $editedJSON)
          .font(.mono)
          .foregroundColor(.foreground)
          .scrollContentBackground(.hidden)
          .padding(Spacing.sm)
          .background(Color.cellBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          .frame(maxHeight: .infinity)
      } else {
        GeometryReader { geometry in
          ScrollView([.vertical, .horizontal], showsIndicators: true) {
            HighlightedJSONText(json: formattedJSON)
              .padding(Spacing.sm)
              .frame(
                minWidth: geometry.size.width,
                minHeight: geometry.size.height,
                alignment: .topLeading
              )
          }
          .background(Color.cellBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        }
      }
    }
  }

  private var formattedJSON: String {
    if isPrettyPrinted {
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let prettyData = try? JSONSerialization.data(
          withJSONObject: object, options: .prettyPrinted
        ),
        let prettyString = String(data: prettyData, encoding: .utf8)
      else {
        return json
      }
      return prettyString
    }
    return json
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
