//
//  SetCellsValuePopover.swift
//  Dblore
//
//  "Set Value..." popover of the result grid: one value staged into the clicked column of every
//  selected row, as text, NULL, or the column DEFAULT (only where the engine's UPDATE has it).
//

import SwiftUI

struct SetCellsValuePopover: View {
  let columnName: String
  let rowCount: Int
  /// Shows the DEFAULT button (`DatabaseCapabilities.supportsDefaultInUpdate`)
  let offersDefault: Bool
  let onSet: (StagedCellValue) -> Void

  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(rowCount == 1 ? "\(columnName) in 1 row" : "\(columnName) in \(rowCount) rows")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.foreground)
        .lineLimit(1)
      TextField("Value", text: $text)
        .textFieldStyle(.plain)
        .font(.monoMedium)
        .inputCapsuleStyle(onPopover: true)
        .onSubmit { onSet(.value(.string(text))) }
      HStack(spacing: Spacing.sm) {
        Button("NULL") { onSet(.value(.null)) }
          .buttonStyle(SecondaryButtonStyle())
        if offersDefault {
          Button("DEFAULT") { onSet(.serverDefault) }
            .buttonStyle(SecondaryButtonStyle())
        }
        Spacer()
        Button("Set") { onSet(.value(.string(text))) }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .popoverContentPadding()
    .frame(width: 280)
  }
}
