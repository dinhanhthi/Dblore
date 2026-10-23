//
//  MongoJSONDocumentsView.swift
//  Dblore
//
//  JSON view of a MongoDB data viewer page: the page's documents (the DocumentTreeModel
//  conversion of the result rows, so the same documents as the grid and the cards) as one
//  indented Extended JSON array, relaxed or canonical. The text is read-only and selectable, with
//  the text view's find bar (Find button or Cmd+F) and Copy All. It is rendered off the main actor
//  per result and format.
//

import AppKit
import SwiftUI

struct MongoJSONDocumentsView: View {
  let result: CellResult
  /// Kept on the tab's view model, so a new page, sort or filter keeps the choice
  @Binding var format: MongoRelaxedJSON.Format
  /// Changes when Cmd+F asks for the find bar
  let findRequest: Int

  @State private var text: String?
  @State private var finder = TextFindHandle()
  /// Result and format `text` was rendered from
  @State private var renderedKey: RenderKey?

  private struct RenderKey: Equatable {
    let stamp: Date
    let format: MongoRelaxedJSON.Format
  }

  private var key: RenderKey { RenderKey(stamp: result.timestamp, format: format) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(Color.border).frame(height: 1)
      if let text, renderedKey == key {
        ReadOnlyTextView(text: text, version: key, finder: finder)
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color.appBackground)
    .task(id: key) { await render() }
    .onChange(of: findRequest) { finder.showFindBar() }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      CapsuleTabPicker(
        selection: $format,
        tabs: [MongoRelaxedJSON.Format.relaxedExtendedJSON, .canonicalExtendedJSON], height: 28
      ) { value in
        CapsuleTabLabel(
          text: value == .relaxedExtendedJSON ? "Relaxed" : "Canonical",
          isSelected: format == value)
      }
      .fitsContent()
      .accessibilityLabel("Extended JSON format")
      .help("Extended JSON: relaxed (plain numbers and dates) or canonical (every type wrapped)")
      Spacer(minLength: Spacing.sm)
      Button(action: finder.showFindBar) {
        Label("Find", systemImage: "magnifyingglass")
      }
      .buttonStyle(GhostButtonStyle())
      .disabled(text == nil || renderedKey != key)
      .help("Find in the JSON text")
      Button(action: copyAll) {
        Label("Copy All", systemImage: "doc.on.doc")
      }
      .buttonStyle(GhostButtonStyle())
      .disabled(text == nil || renderedKey != key)
      .help("Copy the page's documents as Extended JSON")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private func render() async {
    let key = self.key
    let columns = result.columns
    let rows = result.rows
    let rendered = await Task.detached(priority: .userInitiated) {
      PerfSignpost.interval("mongo.jsonView") {
        Self.text(columns: columns, rows: rows, format: key.format)
      }
    }.value
    guard !Task.isCancelled else { return }
    text = rendered
    renderedKey = key
  }

  /// The page as one indented Extended JSON array, documents converted as in the Documents view.
  nonisolated private static func text(
    columns: [ColumnInfo], rows: [[CellValue]], format: MongoRelaxedJSON.Format
  ) -> String {
    let documents = rows.map { DocumentTreeModel.document(row: $0, columns: columns) }
    return MongoRelaxedJSON.render(.array(documents), as: format, indented: true)
  }

  private func copyAll() {
    guard let text, renderedKey == key else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// The text view shown by the JSON view, so its Find button and Cmd+F can open the find bar
private final class TextFindHandle {
  weak var textView: NSTextView?

  func showFindBar() {
    guard let textView, let window = textView.window else { return }
    window.makeFirstResponder(textView)
    let sender = NSMenuItem()
    sender.tag = NSTextFinder.Action.showFindInterface.rawValue
    textView.performFindPanelAction(sender)
  }
}

/// Read-only, selectable monospaced text with the find bar. `version` changes with the text, so an
/// update compares it instead of the (possibly large) text.
private struct ReadOnlyTextView<Version: Equatable>: NSViewRepresentable {
  let text: String
  let version: Version
  let finder: TextFindHandle

  final class Coordinator {
    var version: Version?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.drawsBackground = false
    textView.font = ResultGridCoordinator.font
    textView.textColor = NSColor(Color.foreground)
    textView.textContainerInset = NSSize(width: Spacing.sm, height: Spacing.sm)
    textView.string = text
    context.coordinator.version = version
    finder.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard context.coordinator.version != version,
      let textView = scrollView.documentView as? NSTextView
    else { return }
    textView.string = text
    context.coordinator.version = version
  }
}
