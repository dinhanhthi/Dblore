//
//  AIOutsideToolCardView.swift
//  Dblore
//
//  An outside MCP tool call the model asked for: the server, the tool and the arguments it
//  would send, then Run once / Deny. Nothing is sent before Run once, and every call asks
//  again. Run once stays off for a moment after the card shows (`canRun`), so a click meant
//  for something else never runs it. A saved card has no buttons. Every field is sanitized
//  again here: saved chats are plain JSON.
//

import SwiftUI

struct AIOutsideToolCardView: View {
  let call: AIOutsideCall
  /// Run once (true) or Deny (false); nil unless the call waits for the user
  let onDecide: ((Bool) -> Void)?
  /// False while Run once is still ignored (`AIAssistantViewModel.outsideApproveDelay`)
  var canRun = true

  private static let argumentsHeight: CGFloat = 160

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Rectangle().fill(Color.border).frame(height: 1)
      VStack(alignment: .leading, spacing: Spacing.sm) {
        field("Server", OutsideMCPText.display(call.serverName, limit: OutsideMCPServer.nameLimit))
        field("Tool", OutsideMCPText.display(call.tool, limit: MCPClient.maxToolNameLength))
        arguments
        status
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.sm)
      .background(Color.cellBackground)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  private var header: some View {
    HStack(spacing: Spacing.xs) {
      Text("Outside tool")
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      Spacer(minLength: 0)
      if let onDecide, call.state == .waiting {
        Button("Deny") { onDecide(false) }
          .buttonStyle(AICodeActionButtonStyle())
          .help("Do not call the tool; the assistant is told it was denied")
        Button("Run once") { onDecide(true) }
          .buttonStyle(AICodeActionButtonStyle())
          .disabled(!canRun)
          .help("Send this one call to the server; the next call asks again")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.cardHeaderBackground)
  }

  private func field(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
      Text(label)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Text(verbatim: value)
        .font(.labelText)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .lineLimit(2)
    }
  }

  /// Short arguments as they are, long ones in a scroll view of `argumentsHeight`
  private var arguments: some View {
    ViewThatFits(in: .vertical) {
      argumentsText
      ScrollView(.vertical) { argumentsText }
    }
    .frame(maxWidth: .infinity, maxHeight: Self.argumentsHeight, alignment: .topLeading)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.sm)))
  }

  private var argumentsText: some View {
    Text(
      verbatim: OutsideMCPText.untrusted(
        call.arguments, limit: AITools.maxShownArgumentScalars, note: "\n…")
    )
    .font(.monoSmall)
    .foregroundColor(.foreground)
    .textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var status: some View {
    let (text, isError) = statusText
    return Text(verbatim: text)
      .font(.small)
      .foregroundColor(isError ? .destructive : .foregroundMuted)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var statusText: (String, Bool) {
    switch call.state {
    case .waiting:
      onDecide == nil
        ? ("Not run.", false) : ("Nothing is sent until you press Run once.", false)
    case .running: ("Running…", false)
    case .denied: ("Denied. Nothing was sent.", false)
    case .ran: ("Ran. The result went to the assistant as untrusted data.", false)
    case .failed:
      (
        "Failed: "
          + OutsideMCPText.display(call.message ?? "", limit: 1_000), true
      )
    case .stopped: ("Stopped. No answer reached the assistant.", false)
    }
  }
}

#Preview("AIOutsideToolCardView") {
  VStack(spacing: Spacing.md) {
    AIOutsideToolCardView(
      call: AIOutsideCall(
        serverName: "Docs search", tool: "search",
        arguments: "{\n  \"query\" : \"index types\"\n}", state: .waiting),
      onDecide: { _ in })
    AIOutsideToolCardView(
      call: AIOutsideCall(
        serverName: "Docs search", tool: "search", arguments: "{}", state: .failed,
        message: "The server refused the token (HTTP 401)."),
      onDecide: nil)
  }
  .padding(Spacing.md)
  .frame(width: ComponentSize.sidebarWidth)
  .background(Color.appBackground)
}
