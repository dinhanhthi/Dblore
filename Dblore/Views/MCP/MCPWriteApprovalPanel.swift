//
//  MCPWriteApprovalPanel.swift
//  Dblore
//
//  The app-level panel for MCP write approvals: an NSPanel owned by `MCPWriteApprovalCenter`,
//  shown over every window (the Welcome window alone included). It shows the center's current
//  request: connection, classification, the exact statement (scrollable, nothing collapsed,
//  with its line and character counts; the invisible characters a string literal may hold shown
//  as `[U+200D]` markers) above the buttons, and the client name as unverified,
//  with Deny (Escape), Deny all (more than one waiting) and Approve once. Approve is not the
//  default button, so Return never approves, and it stays disabled for the center's approve
//  delay after a request shows, so a click or key meant for something else never approves.
//  A new request activates the app and bounces the Dock icon.
//

import AppKit
import SwiftUI

@MainActor
final class MCPWriteApprovalPanel: MCPWriteApprovalPresenting {
  private var panel: NSPanel?
  /// The request on screen, so an update for the same one does not bounce again
  private var shownID: UUID?

  func update(_ center: MCPWriteApprovalCenter) {
    guard let current = center.current else {
      panel?.orderOut(nil)
      shownID = nil
      return
    }
    guard shownID != current.id else { return }
    let isNew = panel == nil
    let panel = panel ?? makePanel(center)
    self.panel = panel
    shownID = current.id
    if isNew || !panel.isVisible { panel.center() }
    NSApp.requestUserAttention(.criticalRequest)
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }

  private func makePanel(_ center: MCPWriteApprovalCenter) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled],
      backing: .buffered, defer: true)
    panel.title = "MCP Write Request"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: MCPWriteApprovalView(center: center))
    return panel
  }
}

/// The current request of `center`, or nothing.
private struct MCPWriteApprovalView: View {
  let center: MCPWriteApprovalCenter

  var body: some View {
    Group {
      if let request = center.current {
        content(request, waiting: center.queue.count - 1)
      }
    }
    .frame(width: 520)
    .background(Color.cardHeaderBackground)
  }

  private func content(_ request: MCPWriteApprovalRequest, waiting: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.shield.fill")
          .foregroundColor(.warning)
        Text("An agent wants to change \(request.connectionName)")
          .font(.subheading)
          .foregroundColor(.foreground)
          .lineLimit(2)
      }
      VStack(alignment: .leading, spacing: Spacing.xs) {
        row("Connection", "\(request.connectionName) (\(request.engine))")
        row("Change", request.classification)
      }
      Text(Self.counts(request.statement))
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
      ScrollView {
        Text(MCPToolService.markingInvisibles(request.statement))
          .font(.mono)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Spacing.md)
      }
      .frame(minHeight: 80, maxHeight: 220)
      .background(Color.controlBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
      ForEach(request.warnings, id: \.self) { warning in
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(warning)
        }
        .font(.bodyText)
        .foregroundColor(.warning)
      }
      Text("Client (unverified): \(request.clientName)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .lineLimit(1)
        .truncationMode(.tail)
      Text(
        waiting > 0
          ? "Runs once if approved. Denied after 2 minutes without an answer. \(waiting) more waiting."
          : "Runs once if approved. Denied after 2 minutes without an answer."
      )
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
      HStack(spacing: Spacing.md) {
        if waiting > 0 {
          Button("Deny all") { center.denyAll() }
            .buttonStyle(FilledSecondaryButtonStyle())
        }
        Spacer()
        Button("Deny") { center.decide(request.id, approved: false) }
          .buttonStyle(FilledSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
        Button("Approve once") { center.decide(request.id, approved: true) }
          .buttonStyle(DangerButtonStyle())
          .disabled(!center.approveEnabled)
      }
    }
    .padding(Spacing.lg)
  }

  /// "N lines, M characters" of the statement, as the agent sent it.
  private static func counts(_ statement: String) -> String {
    let lines = MCPToolService.lineCount(statement)
    let characters = statement.count
    return "\(lines) \(lines == 1 ? "line" : "lines"), "
      + "\(characters) \(characters == 1 ? "character" : "characters")"
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      Text(label)
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
        .frame(width: 80, alignment: .leading)
      Text(value)
        .font(.bodyText)
        .foregroundColor(.foreground)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }
}
