//
//  AIChatHistoryPopover.swift
//  Dblore
//
//  Saved conversations of the workspace: open one or delete it
//

import SwiftUI

struct AIChatHistoryPopover: View {
  @Bindable var assistant: AIAssistantViewModel

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Chat history")
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.xs)

      if assistant.conversations.isEmpty {
        Text("No saved chats yet")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .padding(.horizontal, Spacing.xs)
      } else {
        ScrollView {
          LazyVStack(spacing: Spacing.xxs) {
            ForEach(assistant.conversations) { conversation in
              AIChatHistoryRow(
                conversation: conversation,
                isCurrent: conversation.id == assistant.conversationId,
                onOpen: {
                  assistant.openConversation(id: conversation.id)
                  dismiss()
                },
                onDelete: { assistant.deleteConversation(id: conversation.id) }
              )
            }
          }
        }
        .frame(maxHeight: 360)
      }
    }
    .padding(Spacing.sm)
    .frame(width: 300)
  }
}

private struct AIChatHistoryRow: View {
  let conversation: AIConversation
  let isCurrent: Bool
  let onOpen: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(conversation.title)
            .font(.small)
            .foregroundColor(.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
          Text(conversation.updatedAt, format: .relative(presentation: .named))
            .font(.caption2)
            .foregroundColor(.foregroundMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .linkPointer()

      Button(action: onDelete) {
        Image(systemName: "trash").foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .opacity(isHovering ? 1 : 0)
      .help("Delete chat")
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, Spacing.xxs)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(
          isCurrent
            ? Color.cellBackgroundHover
            : isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
    )
    .onHover { isHovering = $0 }
  }
}
