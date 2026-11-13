//
//  RedisReplyView.swift
//  Dblore
//
//  One Redis reply in two modes: Grid (one row per node, depth first: path, type, value; nested
//  nodes indented, map children marked key / value, values one escaped line cut for display) and
//  Raw (redis-cli style text). Both are built once per reply off the main actor (a new `stamp`
//  cancels the build in flight; the tree is never compared), and both stay mounted once shown, so
//  a mode switch rebuilds nothing; the Raw text view is mounted the first time Raw is shown for a
//  reply, the Grid's list lays out only the rows on screen. A reply cut short arrives as its
//  Grid rows only (a cut reply is no tree): it shows the Grid under the banner, without Raw.
//  Server text is shown as plain text only: no Markdown, attributes or link detection, and
//  invisible or line-breaking characters escaped (`RedisDisplayText`).
//

import AppKit
import SwiftUI

struct RedisReplyView: View, Equatable {
  /// What is shown: a whole reply, or the Grid rows of a reply cut short
  enum Input: Sendable {
    case reply(RedisReply)
    case rows([RedisReplyDisplayRow])
  }

  let input: Input
  /// Changes whenever `input` does (e.g. the command result's id): the view rebuilds on it
  /// instead of comparing the reply
  let stamp: UUID
  /// Banner over the reply when it was cut short; nil shows none
  var truncatedMessage: String? = nil

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.stamp == rhs.stamp && lhs.truncatedMessage == rhs.truncatedMessage
  }

  @State private var mode: Mode = .grid
  /// The Grid rows and Raw text of `input`; nil while they are built
  @State private var content: Content?
  /// Counts the builds, so the Raw text view compares a number instead of the text
  @State private var builds = 0
  /// Raw has been shown for this reply, so its text view stays mounted
  @State private var rawMounted = false
  /// The user switched to Raw, so its text view takes the keyboard; a new reply leaves it alone
  @State private var rawTakesFocus = false

  enum Mode: Hashable {
    case grid, raw

    var title: String { self == .grid ? "Grid" : "Raw" }
  }

  nonisolated private struct Content: Sendable {
    let rows: [RedisReplyDisplayRow]
    /// Nil for rows of a reply cut short: Raw is not offered
    let rawText: String?
    let version: Int
  }

  /// Raw is offered for a whole reply only
  private var hasRaw: Bool {
    if case .reply = input { return true }
    return false
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(Color.border).frame(height: 1)
      if let truncatedMessage {
        TruncatedBanner(message: truncatedMessage)
      }
      if let content {
        ZStack {
          RedisReplyGrid(rows: content.rows)
            .shown(mode == .grid)
          if let rawText = content.rawText, rawMounted || mode == .raw {
            RedisRawTextView(
              text: rawText, version: content.version, isShown: mode == .raw,
              takesFocus: rawTakesFocus
            )
            .shown(mode == .raw)
          }
        }
      } else {
        LoadingPlaceholder()
      }
    }
    .background(Color.appBackground)
    // The stamp, not the tree: a long reply is never compared
    .task(id: stamp) { await build() }
    .onChange(of: mode) { _, newMode in
      if newMode == .raw { rawMounted = true }
      rawTakesFocus = newMode == .raw && content != nil
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      if hasRaw {
        CapsuleTabPicker(selection: $mode, tabs: [Mode.grid, .raw], height: 28) { value in
          CapsuleTabLabel(text: value.title, isSelected: mode == value)
        }
        .fitsContent()
        .accessibilityLabel("Reply view")
        .help("Grid: one row per reply node. Raw: the reply as text.")
      } else {
        Text("Grid")
          .font(.small.weight(.semibold))
          .foregroundColor(.foregroundMuted)
          .frame(height: 28)
          .help("A reply cut short shows its Grid rows only")
      }
      Spacer(minLength: Spacing.sm)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  /// Builds the Grid rows and Raw text of `reply` off the main actor. The detached build does not
  /// inherit this task's cancellation, so a cancel (a new reply, the view gone) is forwarded to it
  /// and its builders stop early.
  private func build() async {
    content = nil
    if !hasRaw { mode = .grid }
    rawMounted = mode == .raw
    rawTakesFocus = false
    builds += 1
    let version = builds
    let input = self.input
    let task = Task.detached(priority: .userInitiated) { () -> Content? in
      PerfSignpost.interval("redis.replyView") {
        switch input {
        case .rows(let rows):
          return Content(rows: rows, rawText: nil, version: version)
        case .reply(let reply):
          let rows = reply.displayRows()
          guard !Task.isCancelled else { return nil }
          let rawText = reply.rawText
          guard !Task.isCancelled else { return nil }
          return Content(rows: rows, rawText: rawText, version: version)
        }
      }
    }
    let built = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    guard !Task.isCancelled, let built else { return }
    content = built
  }
}

// MARK: - Grid

/// The reply's nodes in a list, which only lays out the rows on screen
private struct RedisReplyGrid: View {
  let rows: [RedisReplyDisplayRow]

  static let pathWidth: CGFloat = 260
  static let typeWidth: CGFloat = 72
  /// Deeper nodes keep this indentation, so the path column stays readable
  static let maxIndentLevels = 12
  static let indentStep: CGFloat = 14

  var body: some View {
    VStack(spacing: 0) {
      columnHeader
      Rectangle().fill(Color.border).frame(height: 1)
      List(0..<rows.count, id: \.self) { index in
        RedisReplyGridRow(row: rows[index])
          .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
          .listRowSeparator(.hidden)
          .listRowBackground(
            index.isMultiple(of: 2) ? Color.clear : Color.tableRowAlternate)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 22)
    }
  }

  private var columnHeader: some View {
    HStack(spacing: Spacing.sm) {
      Text("Path").frame(width: Self.pathWidth, alignment: .leading)
      Text("Type").frame(width: Self.typeWidth, alignment: .leading)
      Text("Value").frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.small.weight(.semibold))
    .foregroundColor(.foregroundMuted)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(Color.tableHeaderBackground)
  }
}

private struct RedisReplyGridRow: View {
  let row: RedisReplyDisplayRow

  var body: some View {
    HStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Text(verbatim: row.path)
          .font(.monoMedium)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.head)
        if let role = row.role {
          Text(verbatim: role.rawValue)
            .font(.smallest)
            .foregroundColor(.foregroundSubtle)
        }
      }
      .padding(
        .leading,
        CGFloat(min(row.depth, RedisReplyGrid.maxIndentLevels)) * RedisReplyGrid.indentStep
      )
      .frame(width: RedisReplyGrid.pathWidth, alignment: .leading)

      Text(verbatim: row.type)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .frame(width: RedisReplyGrid.typeWidth, alignment: .leading)

      Text(verbatim: row.value)
        .font(.monoMedium)
        .foregroundColor(valueColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: 22)
  }

  private var valueColor: Color {
    switch row.type {
    case "error": .destructive
    case "null", "array", "set", "map", "push": .foregroundMuted
    case "integer", "double", "bignum": .gridNumber
    case "boolean": .gridBoolean
    default: .gridForeground
    }
  }
}

// MARK: - Raw

/// Read-only, selectable monospaced plain text. `version` changes with the text, so an update
/// compares it instead of the (possibly large) text. Hidden at the AppKit level while not
/// `isShown`, so it takes no clicks, scrolls, cursor or first responder over the Grid; hiding it
/// gives up the keyboard it holds. `takesFocus` (a switch to Raw) makes it first responder once,
/// so the hidden Grid no longer gets the arrow keys and Cmd+F.
private struct RedisRawTextView: NSViewRepresentable {
  let text: String
  let version: Int
  let isShown: Bool
  let takesFocus: Bool

  final class Coordinator {
    var version: Int?
    /// Set once the text view took the keyboard for the current switch to Raw
    var tookFocus = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    scrollView.isHidden = !isShown
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.drawsBackground = false
    textView.font = ResultGridCoordinator.font
    textView.textColor = NSColor(Color.foreground)
    textView.textContainerInset = NSSize(width: Spacing.sm, height: Spacing.sm)
    textView.string = text
    context.coordinator.version = version
    updateFocus(scrollView, context: context)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    updateFocus(scrollView, context: context)
    scrollView.isHidden = !isShown
    guard context.coordinator.version != version,
      let textView = scrollView.documentView as? NSTextView
    else { return }
    textView.string = text
    context.coordinator.version = version
  }

  /// Gives up the keyboard (the text view or its find bar) before the view is hidden, and takes
  /// it once per switch to Raw, on the next main turn, when the view is in a window
  private func updateFocus(_ scrollView: NSScrollView, context: Context) {
    if !isShown, let window = scrollView.window,
      let responder = window.firstResponder as? NSView, responder.isDescendant(of: scrollView)
    {
      window.makeFirstResponder(nil)
    }
    guard takesFocus, isShown else {
      if !takesFocus { context.coordinator.tookFocus = false }
      return
    }
    guard !context.coordinator.tookFocus else { return }
    context.coordinator.tookFocus = true
    DispatchQueue.main.async { [weak scrollView] in
      guard let scrollView, !scrollView.isHidden, let window = scrollView.window,
        let textView = scrollView.documentView as? NSTextView
      else { return }
      window.makeFirstResponder(textView)
    }
  }
}

// MARK: - Mode visibility

extension View {
  /// Keeps the view mounted but hidden, out of hit testing and accessibility when not `isShown`
  fileprivate func shown(_ isShown: Bool) -> some View {
    opacity(isShown ? 1 : 0)
      .allowsHitTesting(isShown)
      .accessibilityHidden(!isShown)
  }
}

// MARK: - Banner and placeholder

private struct TruncatedBanner: View {
  let message: String

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
        .accessibilityHidden(true)
      Text(verbatim: message)
        .font(.small)
        .foregroundColor(.foreground)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .tintedChromeGlass(.warning)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.warning.opacity(0.4)).frame(height: 1)
    }
  }
}

/// Fills the reply's place while it is built; its spinner fades in after 150 ms, so a fast build
/// never flashes it
private struct LoadingPlaceholder: View {
  @State private var showsSpinner = false

  var body: some View {
    ProgressView()
      .controlSize(.small)
      .tint(.accent)
      .opacity(showsSpinner ? 1 : 0)
      .animation(.easeIn(duration: 0.15), value: showsSpinner)
      // Opt out of the app-wide animation kill switch, only for the fade
      .transaction(value: showsSpinner) { $0.disablesAnimations = false }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task {
        try? await Task.sleep(for: .milliseconds(150))
        showsSpinner = true
      }
  }
}

// MARK: - Previews

#Preview("Redis reply") {
  RedisReplyView(
    input: .reply(
      .array([
        .map([
          RedisReplyPair(key: .bulk(.text("name")), value: .bulk(.text("Ada"))),
          RedisReplyPair(
            key: .simple(.text("tags")),
            value: .array([.bulk(.text("admin")), .bulk(.bytes(Data([0xDE, 0xAD, 0x00])))])),
        ]),
        .error(.text("WRONGTYPE Operation against a key holding the wrong kind of value")),
        .integer(42),
        .null,
        .double("3.14"),
        .boolean(true),
      ])),
    stamp: UUID(),
    truncatedMessage: "The reply was cut at 10,000 rows."
  )
  .frame(width: 720, height: 420)
}
