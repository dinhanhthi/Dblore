//
//  How an allowed write is applied.
//  Dblore
//

import SwiftUI

/// Explains protection level versus commit style. Opened from the footer and Settings.
struct CommitStyleHelpView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("How writes are handled")
        .font(.small)
        .fontWeight(.semibold)
        .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Protection level decides what is allowed (None, Schema Protected, Read-Only).")
        Text("Commit style decides how an allowed write is applied.")
      }
      .font(.smallest)
      .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(CommitStyle.allCases, id: \.self) { style in
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(style.title)
              .font(.smallest)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
            Text(style.summary)
              .font(.smallest)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(
          "Review keeps changes in a pending transaction. The yellow bar shows them. Commit saves, Roll Back discards."
        )
        Text("SELECT is never confirmed. The Default commit style in Settings is used for new connections.")
        Text(
          "Lowering the style from Review or Password asks for your Safe Mode password, if one is set."
        )
      }
      .font(.smallest)
      .foregroundColor(.foreground)
    }
    .padding(Spacing.md)
    .frame(width: 300, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Explains what each protection level blocks. Opened from the protection menu.
struct ProtectionLevelHelpView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("What queries are allowed")
        .font(.small)
        .fontWeight(.semibold)
        .foregroundColor(.foreground)

      Text(
        "Protection level decides which statements can run. Commit style decides how an allowed write is applied."
      )
      .font(.smallest)
      .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(ConnectionProtectionLevel.allCases, id: \.self) { level in
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(level.displayName)
              .font(.smallest)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
            Text(Self.detail(for: level))
              .font(.smallest)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      Text(
        "Lowering the level while the commit style is Password asks for your Safe Mode password, if one is set."
      )
      .font(.smallest)
      .foregroundColor(.foreground)
    }
    .padding(Spacing.md)
    .frame(width: 300, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private static func detail(for level: ConnectionProtectionLevel) -> String {
    switch level {
    case .none:
      "All queries allowed."
    case .schemaOnly:
      "Blocks CREATE, DROP, ALTER, and TRUNCATE. INSERT, UPDATE, and DELETE still run."
    case .readOnly:
      "Blocks every change to data and schema. SELECT still runs."
    }
  }
}
