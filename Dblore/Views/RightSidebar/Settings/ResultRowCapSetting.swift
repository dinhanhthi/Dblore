//
//  ResultRowCapSetting.swift
//  Dblore
//
//  Global result row cap control (Notebook and Editor), shared by the settings sidebar and
//  the settings modal. A connection's row cap override still wins.
//

import SwiftUI

struct ResultRowCapSetting: View {
  @Bindable var appSettings: AppSettings

  private var range: ClosedRange<Int> { SessionBrakeLimits.rowCapRange }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("Result row cap")
          .font(.subheading)
          .foregroundColor(.foreground)

        Spacer()

        HStack(spacing: Spacing.sm) {
          TextField(
            "\(AppSettings.defaultResultRowCap)", value: $appSettings.resultRowCap,
            format: .number.grouping(.never)
          )
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .frame(width: 80)
          Stepper(
            "",
            onIncrement: {
              appSettings.resultRowCap = AppSettings.steppedResultRowCap(
                appSettings.resultRowCap, up: true)
            },
            onDecrement: {
              appSettings.resultRowCap = AppSettings.steppedResultRowCap(
                appSettings.resultRowCap, up: false)
            }
          )
          .labelsHidden()
        }
      }

      Text(
        "Rows shown per statement; queries are not rewritten — reading stops after this many rows. "
          + "Between \(range.lowerBound) and \(range.upperBound); a connection's row cap override wins."
      )
      .font(.small)
      .foregroundColor(.foregroundSubtle)
    }
  }
}
