//
//  MongoExplainSheet.swift
//  Dblore
//
//  Explain of the MongoDB collection screen (the Documents query or the Aggregations pipeline),
//  presented while `MongoCollectionModel.explainState` is not idle: a progress with Cancel, the
//  error, or a summary strip (time, returned, examined, index or collection scan) over the plan
//  tree or the raw reply, with Copy.
//

import AppKit
import SwiftUI

struct MongoExplainSheet: View {
  let model: MongoCollectionModel

  @State private var mode: ExplainDisplayMode = .plan
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer
    }
    .frame(width: 760, height: 540)
    .background(Color.appBackground)
  }

  // MARK: - Header and footer

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text("Explain")
        .font(.subheading)
        .foregroundColor(.foreground)
      Text(model.collection)
        .font(.monoMedium)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(action: model.dismissExplain) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      Text("Explain runs the query with execution statistics and returns no documents.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .lineLimit(1)
      Spacer()
      if case .done(let text, _, _) = model.explainState {
        Button(copied ? "Copied" : "Copy JSON") { copy(text) }
          .buttonStyle(SecondaryButtonStyle())
          .help("Copy the raw explain reply")
      }
      if model.explainState == .running {
        Button("Cancel", action: model.cancelExplain)
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
          .help("Stop the explain")
      } else {
        Button("Close", action: model.dismissExplain)
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
    }
    .modalBarPadding()
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch model.explainState {
    case .idle:
      EmptyView()
    case .running:
      VStack(spacing: Spacing.sm) {
        ProgressView()
          .controlSize(.small)
        Text("Running explain…")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ScrollView {
        Text(message)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    case .done(let text, let plan, let summary):
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if let summary {
          summaryStrip(summary)
        }
        if let plan {
          ExplainDisplayPicker(mode: $mode)
          if mode == .plan {
            ExplainPlanView(plan: plan)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            raw(text)
          }
        } else {
          raw(text)
        }
      }
    }
  }

  /// Time, returned and examined counts, then the indexes used or a collection scan warning
  private func summaryStrip(_ summary: MongoExplainAdapter.Summary) -> some View {
    HStack(spacing: Spacing.md) {
      metric("Time", summary.executionTimeMillis.map { "\($0) ms" })
      metric("Returned", summary.nReturned.map(String.init))
      metric("Docs examined", summary.totalDocsExamined.map(String.init))
      metric("Keys examined", summary.totalKeysExamined.map(String.init))
      if !summary.indexNames.isEmpty {
        metric(
          summary.indexNames.count == 1 ? "Index" : "Indexes",
          summary.indexNames.joined(separator: ", "))
      }
      if summary.usesCollectionScan {
        Label("Collection scan", systemImage: "exclamationmark.triangle")
          .font(.small)
          .foregroundColor(.warning)
          .help("A stage reads every document of the collection: no index serves the query")
      }
      Spacer(minLength: 0)
    }
    .lineLimit(1)
  }

  @ViewBuilder
  private func metric(_ title: String, _ value: String?) -> some View {
    if let value {
      HStack(spacing: Spacing.xs) {
        Text(title)
          .font(.small)
          .foregroundColor(.foregroundMuted)
        Text(value)
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .truncationMode(.middle)
      }
      .help("\(title): \(value)")
    }
  }

  /// The raw reply, selectable, scrolling both ways
  private func raw(_ text: String) -> some View {
    ScrollView([.vertical, .horizontal]) {
      Text(text)
        .font(.monoSmall)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize()
        .padding(Spacing.sm)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    copied = true
  }
}
