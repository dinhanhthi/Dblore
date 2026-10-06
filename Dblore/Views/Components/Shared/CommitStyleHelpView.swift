//
//  How an allowed write is applied.
//  Dblore
//

import SwiftUI

/// Explains protection level versus commit style. Opened from the footer and Settings.
struct CommitStyleHelpView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("How writes are handled")
        .font(.heading)
        .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Protection level decides what is allowed (None, Schema Protected, Read-Only).")
        Text("Commit style decides how an allowed write is applied.")
      }
      .font(.bodyText)
      .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(CommitStyle.allCases, id: \.self) { style in
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(style.title)
              .font(.bodyText)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
            Text(style.summary)
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(
          "Review keeps changes in a pending transaction. The yellow bar shows them. Commit saves, Roll Back discards."
        )
        Text("SELECT is never confirmed. The Default commit style in Settings is used for new connections.")
        Text(
          "Lowering the style from Review or Password asks for your Safe Mode password, if one is set."
        )
      }
      .font(.bodyText)
      .foregroundColor(.foreground)
    }
    .padding(Spacing.lg)
    .frame(width: 340, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}
