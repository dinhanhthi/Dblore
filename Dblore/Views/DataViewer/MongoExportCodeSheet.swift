//
//  MongoExportCodeSheet.swift
//  Dblore
//
//  Export of a MongoDB `find` or `aggregate` of the collection screen (the Documents draft or the
//  Aggregations pipeline) as driver code: a language picker, imports and connection toggles, the
//  code, selectable, and Copy. Nothing runs.
//

import AppKit
import SwiftUI

struct MongoExportCodeSheet: View {
  /// A command to export; identifiable so `.sheet(item:)` opens a sheet per request
  struct Request: Identifiable {
    let id = UUID()
    let command: MongoCommand
    let database: String
  }

  let request: Request

  @Environment(\.dismiss) private var dismiss
  @State private var language: MongoDriverCode.Language = .node
  @State private var includeImports = true
  @State private var includeConnection = false
  @State private var copied = false

  private static let languageTabWidth: CGFloat = 72

  /// The code for the current choices; nil when the command has no driver code
  private var code: String? {
    MongoDriverCode.code(
      for: request.command, database: request.database, language: language,
      includeImports: includeImports, includeConnection: includeConnection)
  }

  var body: some View {
    let code = code
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      VStack(alignment: .leading, spacing: Spacing.sm) {
        controls
        content(code)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer(code)
    }
    .frame(width: 760, height: 540)
    .background(Color.appBackground)
    // A new language or toggle is new code: Copy is offered again
    .onChange(of: code) { copied = false }
  }

  /// The database the code connects to: the data viewer's (the collection screen's), else the
  /// connection's, else the session default, as commands run
  static func database(for viewModel: NotebookViewModel) -> String {
    if let schema = viewModel.dataViewer?.schema, !schema.isEmpty { return schema }
    let configured = viewModel.notebook.connectionConfig?.database ?? ""
    return configured.isEmpty ? MongoSession.defaultDatabase : configured
  }

  // MARK: - Header and footer

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text("Export Code")
        .font(.subheading)
        .foregroundColor(.foreground)
      Text(request.command.collection ?? "")
        .font(.monoMedium)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(action: { dismiss() }) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private func footer(_ code: String?) -> some View {
    HStack(spacing: Spacing.sm) {
      Text("The connection reads the URI from the MONGODB_URI environment variable.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .lineLimit(1)
      Spacer()
      Button(copied ? "Copied" : "Copy") {
        guard let code else { return }
        copy(code)
      }
      .buttonStyle(SecondaryButtonStyle())
      .disabled(code == nil)
      .help("Copy the code")
      Button("Close") { dismiss() }
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.cancelAction)
    }
    .modalBarPadding()
  }

  // MARK: - Content

  /// The language picker, then the imports and connection toggles
  private var controls: some View {
    HStack(spacing: Spacing.md) {
      CapsuleTabPicker(
        selection: $language,
        tabs: MongoDriverCode.Language.allCases,
        height: ResultDisplayPicker.height,
        inset: 2,
        verticalInset: 2
      ) { tab in
        let isSelected = language == tab
        Text(tab.title)
          .font(.small)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundColor(isSelected ? .onAccentFill : .foreground)
          .lineLimit(1)
      }
      .frame(width: Self.languageTabWidth * CGFloat(MongoDriverCode.Language.allCases.count))
      .fixedSize()
      .accessibilityLabel("Driver language")
      Toggle("Include imports", isOn: $includeImports)
        .toggleStyle(.checkbox)
        .font(.small)
        .help("Start with the import lines the code needs")
      Toggle("Include connection", isOn: $includeConnection)
        .toggleStyle(.checkbox)
        .font(.small)
        .help("Wrap the code in a client that connects with MONGODB_URI and prints the results")
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func content(_ code: String?) -> some View {
    if let code {
      ScrollView([.vertical, .horizontal]) {
        Text(code)
          .font(.monoSmall)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize()
          .padding(Spacing.sm)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.cellBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    } else {
      Text("This command cannot be exported as driver code")
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    copied = true
  }
}
