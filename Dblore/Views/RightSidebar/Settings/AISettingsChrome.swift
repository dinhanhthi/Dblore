//
//  AISettingsChrome.swift
//  Dblore
//
//  Neutral model cards for the Settings AI tab.
//

import SwiftUI

struct AIModelCard<Content: View>: View {
  var isCurrent: Bool
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.appBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(isCurrent ? Color.accent : Color.border, lineWidth: 1)
      )
  }
}

struct AIRemoteModelButton: View {
  let name: String
  var isCurrent: Bool
  var showsInUse: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      AIModelCard(isCurrent: isCurrent) {
        HStack(spacing: Spacing.sm) {
          Text(name)
            .font(.bodyText)
            .foregroundColor(.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: Spacing.sm)
          if showsInUse {
            AIInUseBadge()
          }
        }
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}

/// Tier label. Same neutral capsule for Fast, Balanced and Best.
struct AITierBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(Color.inputBackground, in: Capsule())
      .overlay(Capsule().stroke(Color.border, lineWidth: 1))
      .fixedSize()
  }
}

struct AIInUseBadge: View {
  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "checkmark.circle.fill")
      Text("In use")
    }
    .font(.small)
    .foregroundColor(.success)
    .fixedSize(horizontal: true, vertical: false)
  }
}
