//
//  ConnectionFormContent+FormFields.swift
//  Dblore
//
//  Form fields for connection configuration
//

import SwiftUI

// MARK: - Form Fields Extension

extension ConnectionFormContent {

  @ViewBuilder
  func formFields() -> some View {
    // Connection Name (required)
    FormField(label: "Connection Name") {
      TextField(
        "e.g., Production DB, Development Server", text: $connectionConfig.name
      )
      .textFieldStyle(.plain)
      .inputCapsuleStyle()
    }

    // Host and Port
    HStack(spacing: Spacing.md) {
      FormField(label: "Host") {
        TextField("localhost", text: $connectionConfig.host)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }

      FormField(label: "Port") {
        TextField(
          "5432", value: $connectionConfig.port, format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .frame(width: 80)
      }
    }

    // Database
    FormField(label: "Database") {
      TextField("database_name", text: $connectionConfig.database)
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
    }

    // Username
    FormField(label: "Username") {
      TextField("username", text: $connectionConfig.username)
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
    }

    // Password
    FormField(label: "Password") {
      HStack(spacing: 0) {
        if getIsPasswordVisible() {
          TextField("password", text: $connectionConfig.password)
            .textFieldStyle(.plain)
        } else {
          SecureField("password", text: $connectionConfig.password)
            .textFieldStyle(.plain)
        }

        Button(action: { togglePasswordVisibility() }) {
          Image(systemName: getIsPasswordVisible() ? "eye.slash.fill" : "eye.fill")
            .foregroundColor(.foregroundMuted)
            .frame(width: 20, height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .linkPointer()
        .help(getIsPasswordVisible() ? "Hide password" : "Show password")
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
        .padding(.trailing, Spacing.sm)
      }
      .inputCapsuleStyle()
    }

    // SSL Mode
    FormField(label: "SSL Mode") {
      Menu {
        ForEach(SSLMode.allCases, id: \.self) { mode in
          Button(mode.displayName) {
            connectionConfig.sslMode = mode
          }
        }
      } label: {
        HStack {
          Text(connectionConfig.sslMode.displayName)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .linkPointer()
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Timeout
    FormField(label: "Timeout (seconds)") {
      TextField(
        "30", value: $connectionConfig.timeoutSeconds,
        format: .number.grouping(.never)
      )
      .textFieldStyle(.plain)
      .inputCapsuleStyle()
      .frame(width: 80)
    }

    // Common toggles and pickers
    connectionTogglesAndPickers()
  }

  @ViewBuilder
  func connectionStringFields() -> some View {
    // Connection Name (required)
    FormField(label: "Connection Name") {
      TextField(
        "e.g., Production DB, Development Server", text: $connectionConfig.name
      )
      .textFieldStyle(.plain)
      .inputCapsuleStyle()
    }

    FormField(label: "Connection String") {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        TextField(
          "postgresql://username:password@localhost:5432/database", text: connectionStringBinding,
          axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(.body, design: .monospaced))
        .lineLimit(3...6)
        .textAreaCapsuleStyle()
        .onChange(of: connectionStringBinding.wrappedValue) { _, newValue in
          clearParseErrorAndTestResult()
          if !newValue.isEmpty {
            parseConnectionString(newValue)
          }
        }

        Text("Example: postgresql://username:password@localhost:5432/database?sslmode=require")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }
    }

    // SSL Mode picker for connection string mode
    FormField(label: "SSL Mode") {
      Menu {
        ForEach(SSLMode.allCases, id: \.self) { mode in
          Button(mode.displayName) {
            connectionStringSSLModeBinding.wrappedValue = mode
            // Update the config when SSL mode changes
            connectionConfig.sslMode = mode
            clearTestResult()
          }
        }
      } label: {
        HStack {
          Text(connectionStringSSLModeBinding.wrappedValue.displayName)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .linkPointer()
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Common toggles and pickers
    connectionTogglesAndPickers()
  }

  /// Common toggles and pickers used in both form and connection string modes
  @ViewBuilder
  func connectionTogglesAndPickers() -> some View {
    // Remember Connection Toggle
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Remember connection")
          .font(.body)
        Text("Automatically reconnect when you reopen the app")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      Toggle("", isOn: $connectionConfig.rememberConnection)
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(.accent)
        .scaleEffect(0.8)
    }

    // Protection Level Picker
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Protection level")
          .font(.body)
        Text(connectionConfig.protectionLevel.description)
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      Menu {
        ForEach(ConnectionProtectionLevel.allCases, id: \.self) { level in
          Button {
            connectionConfig.protectionLevel = level
          } label: {
            Label(level.displayName, systemImage: level.iconName)
          }
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: connectionConfig.protectionLevel.iconName)
            .font(.caption)
          Text(connectionConfig.protectionLevel.displayName)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .linkPointer()
    }

    // Security Level (Safe Mode) Picker
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Security level")
          .font(.body)
        if let mode = connectionConfig.safeMode {
          Text(mode.shortDescription)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        } else {
          Text("Use global setting (\(AppSettings.shared.safeMode.displayName))")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
      }

      Spacer()

      Menu {
        Button("Use Global") {
          connectionConfig.safeMode = nil
        }
        ForEach(SafeMode.allCases, id: \.self) { mode in
          Button(mode.displayName) {
            connectionConfig.safeMode = mode
          }
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Text(connectionConfig.safeMode?.displayName ?? "Use Global")
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .linkPointer()
    }

    safetySection()
  }

  // MARK: - Safety

  /// Protected mode, server-side session brakes and row cap override
  @ViewBuilder
  func safetySection() -> some View {
    Divider()

    Text("Safety")
      .font(.headline)

    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Protected mode")
          .font(.body)
        Text("Review data changes before they are committed")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      Toggle("", isOn: $connectionConfig.protectedMode)
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(.accent)
        .scaleEffect(0.8)
    }

    brakeField(
      "Statement timeout (seconds)", placeholder: "60",
      value: $connectionConfig.statementTimeoutSeconds,
      range: SessionBrakeLimits.statementTimeoutRange,
      clamp: SessionBrakeLimits.clampStatementTimeout)

    brakeField(
      "Lock timeout (seconds)", placeholder: "5", value: $connectionConfig.lockTimeoutSeconds,
      range: SessionBrakeLimits.lockTimeoutRange, clamp: SessionBrakeLimits.clampLockTimeout)

    brakeField(
      "Idle in transaction timeout (seconds)", placeholder: "600",
      value: $connectionConfig.idleInTransactionTimeoutSeconds,
      range: SessionBrakeLimits.idleTimeoutRange, clamp: SessionBrakeLimits.clampIdleTimeout)

    FormField(label: "Row cap override (empty = global setting)") {
      TextField("Global", value: $connectionConfig.rowCapOverride, format: .number.grouping(.never))
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .frame(width: 120)
        .onChange(of: connectionConfig.rowCapOverride) { _, newValue in
          let clamped = SessionBrakeLimits.clampRowCap(newValue)
          if clamped != newValue { connectionConfig.rowCapOverride = clamped }
        }
    }
  }

  /// Number field + stepper for a session brake, clamped to `range` (non-positive → default)
  private func brakeField(
    _ label: String, placeholder: String, value: Binding<Int>, range: ClosedRange<Int>,
    clamp: @escaping (Int) -> Int
  ) -> some View {
    FormField(label: label) {
      HStack(spacing: Spacing.sm) {
        TextField(placeholder, value: value, format: .number.grouping(.never))
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .frame(width: 80)
        Stepper("", value: value, in: range)
          .labelsHidden()
      }
      .onChange(of: value.wrappedValue) { _, newValue in
        let clamped = clamp(newValue)
        if clamped != newValue { value.wrappedValue = clamped }
      }
    }
  }
}
