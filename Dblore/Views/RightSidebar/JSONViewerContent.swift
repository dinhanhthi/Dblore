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
  /// Text and highlight of `json`, built off the main actor; the content area shows a loading
  /// card until they match `json` and the Pretty Print switch
  @State private var rendered: Rendered?

  /// JSON above this many UTF-8 bytes shows raw in a LargeTextView, never pretty-printed or
  /// highlighted: a SwiftUI Text lays out its whole text on the main thread
  nonisolated static let maxRenderedBytes = 2 * 1024 * 1024

  var body: some View {
    let isLarge = json.utf8.count > Self.maxRenderedBytes
    let shown = isLarge ? nil : currentRender
    VStack(alignment: .leading, spacing: 0) {
      // Fixed header: Path info and Toolbar
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Path info
        Text(path)
          .font(.caption)
          .foregroundColor(.foregroundMuted)

        // Toolbar
        HStack {
          if !isEditing && !isLarge {
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
            .disabled(!isLarge && shown == nil)

            FloatingPanelButton(
              icon: isCopied ? "checkmark" : "doc.on.doc",
              helpText: "Copy JSON",
              useSymbolEffect: true,
              action: copyToClipboard
            )
            .disabled(!isLarge && shown == nil)
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
      } else if isLarge {
        LargeTextView(text: json, wrapsLines: false)
          .frame(maxHeight: .infinity, alignment: .top)
          .background(Color.inputBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      } else if let shown {
        // Nested ScrollViews for both axes to avoid centering issue
        // Horizontal outside so scrollbar is always visible at bottom
        ScrollView(.horizontal, showsIndicators: true) {
          ScrollView(.vertical, showsIndicators: true) {
            HighlightedJSONText(text: shown.highlighted)
              .padding(Spacing.sm)
          }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      } else {
        CellValueLoadingCard()
      }
    }
    .onDisappear(perform: Self.clearCaches)
    .task(id: RenderRequest(json: json, isPrettyPrinted: isPrettyPrinted)) {
      guard !isLarge else { return }
      // Kept as this viewer's own: another viewer may replace the cache
      if let current = currentRender {
        rendered = current
        return
      }
      let json = json
      let isPrettyPrinted = isPrettyPrinted
      let built = await Self.render(
        json, isPrettyPrinted: isPrettyPrinted, palette: JSONSyntaxHighlighter.palette)
      // A newer JSON or Pretty Print switch replaced this one
      guard !Task.isCancelled else { return }
      if isPrettyPrinted { Self.lastPrettyPrint = (json, built.text) }
      HighlightedJSONText.lastHighlight = (built.text, built.highlighted)
      rendered = built
    }
  }

  /// What the content area shows for a JSON and a Pretty Print switch
  nonisolated struct Rendered: Sendable {
    let json: String
    let isPrettyPrinted: Bool
    /// The pretty or raw text, the one Edit and Copy use
    let text: String
    let highlighted: AttributedString
  }

  private struct RenderRequest: Equatable {
    let json: String
    let isPrettyPrinted: Bool
  }

  /// Last pretty-printed JSON and its output: the body re-runs on every state change (copy
  /// feedback, edit) and on parent re-renders with the same JSON
  static var lastPrettyPrint: (json: String, pretty: String)?

  /// The built text of `json` for the Pretty Print switch: this viewer's, else the cache's (a
  /// re-created viewer with the same JSON shows it in the same frame). Nil until it is built.
  private var currentRender: Rendered? {
    if let rendered, rendered.json == json, rendered.isPrettyPrinted == isPrettyPrinted {
      return rendered
    }
    var text = json
    if isPrettyPrinted {
      guard let last = Self.lastPrettyPrint, last.json == json else { return nil }
      text = last.pretty
    }
    guard let highlight = HighlightedJSONText.lastHighlight, highlight.json == text else {
      return nil
    }
    return Rendered(
      json: json, isPrettyPrinted: isPrettyPrinted, text: text, highlighted: highlight.text)
  }

  /// `json` pretty-printed, or unchanged when it does not parse or its pretty form is too large
  /// to highlight (deep nesting indents every element). Cached at any size until the viewer
  /// closes.
  static func prettyPrinted(_ json: String) -> String {
    if let last = lastPrettyPrint, last.json == json { return last.pretty }
    let pretty = prettyPrint(json)
    lastPrettyPrint = (json, pretty)
    return pretty
  }

  /// `prettyPrinted` without the cache
  nonisolated static func prettyPrint(_ json: String) -> String {
    guard
      case .formatted(let text, _) = CellInfoContent.prettyPrintedJSON(
        json, maxOutputBytes: CellInfoContent.maxHighlightedPrettyBytes)
    else { return json }
    return text
  }

  /// Pretty print and highlight; `@concurrent` leaves the main actor (O(size) each)
  @concurrent nonisolated private static func render(
    _ json: String, isPrettyPrinted: Bool, palette: [JSONSyntaxHighlighter.TokenType: Color]
  ) async -> Rendered {
    let text = isPrettyPrinted ? prettyPrint(json) : json
    return Rendered(
      json: json, isPrettyPrinted: isPrettyPrinted, text: text,
      highlighted: JSONSyntaxHighlighter.highlighted(text, palette: palette))
  }

  /// Drops the cached JSON, its pretty copy and highlighted text (the viewer closed)
  static func clearCaches() {
    lastPrettyPrint = nil
    HighlightedJSONText.lastHighlight = nil
  }

  /// The shown text: raw above `maxRenderedBytes`, else the built one (Edit and Copy are off
  /// until it is built)
  private var shownText: String? {
    json.utf8.count > Self.maxRenderedBytes ? json : currentRender?.text
  }

  private func startEdit() {
    guard let text = shownText else { return }
    editedJSON = text
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
    guard let text = shownText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)

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
