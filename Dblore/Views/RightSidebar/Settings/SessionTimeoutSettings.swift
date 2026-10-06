//
//  SessionTimeoutSettings.swift
//  Dblore
//
//  Global statement / lock / idle-in-transaction timeout controls, shared by the settings
//  sidebar and the settings modal. A connection's own timeout still wins.
//

import SwiftUI

struct SessionTimeoutSettings: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      row(
        "Statement timeout (seconds)", value: $appSettings.statementTimeout,
        range: SessionBrakeLimits.statementTimeoutRange)
      row(
        "Lock timeout (seconds)", value: $appSettings.lockTimeout,
        range: SessionBrakeLimits.lockTimeoutRange)
      row(
        "Idle in transaction timeout (seconds)", value: $appSettings.idleTimeout,
        range: SessionBrakeLimits.idleTimeoutRange)

      Text(
        "Applied by the server when a connection opens, so a change reaches open connections "
          + "after they reconnect. A timeout set in a connection's own settings wins."
      )
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
    }
  }

  private func row(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
    HStack {
      Text(title)
        .font(.bodyText)
        .foregroundColor(.foreground)
      Spacer()
      HStack(spacing: Spacing.sm) {
        TextField("", value: value, format: .number.grouping(.never))
          .textFieldStyle(.plain)
          .numberInputCapsuleStyle()
          .frame(width: 80)
        Stepper("", value: value, in: range)
          .compactStepperStyle()
      }
    }
  }
}
