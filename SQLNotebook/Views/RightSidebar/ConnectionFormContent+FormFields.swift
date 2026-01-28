//
//  ConnectionFormContent+FormFields.swift
//  SQLNotebook
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
        "e.g., Production DB, Development Server", text: $viewModel.editingConnectionConfig.name
      )
      .textFieldStyle(.plain)
      .inputStyle()
    }

    // Host and Port
    HStack(spacing: Spacing.md) {
      FormField(label: "Host") {
        TextField("localhost", text: $viewModel.editingConnectionConfig.host)
          .textFieldStyle(.plain)
          .inputStyle()
      }

      FormField(label: "Port") {
        TextField(
          "5432", value: $viewModel.editingConnectionConfig.port, format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .inputStyle()
        .frame(width: 80)
      }
    }

    // Database
    FormField(label: "Database") {
      TextField("database_name", text: $viewModel.editingConnectionConfig.database)
        .textFieldStyle(.plain)
        .inputStyle()
    }

    // Username
    FormField(label: "Username") {
      TextField("username", text: $viewModel.editingConnectionConfig.username)
        .textFieldStyle(.plain)
        .inputStyle()
    }

    // Password
    FormField(label: "Password") {
      HStack(spacing: 0) {
        if getIsPasswordVisible() {
          TextField("password", text: $viewModel.editingConnectionConfig.password)
            .textFieldStyle(.plain)
        } else {
          SecureField("password", text: $viewModel.editingConnectionConfig.password)
            .textFieldStyle(.plain)
        }

        Button(action: { togglePasswordVisibility() }) {
          Image(systemName: getIsPasswordVisible() ? "eye.slash.fill" : "eye.fill")
            .foregroundColor(.foregroundMuted)
            .frame(width: 20, height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
        .padding(.trailing, Spacing.sm)
      }
      .inputStyle()
    }

    // SSL Mode
    FormField(label: "SSL Mode") {
      Picker(selection: $viewModel.editingConnectionConfig.sslMode) {
        ForEach(SSLMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Timeout
    FormField(label: "Timeout (seconds)") {
      TextField(
        "30", value: $viewModel.editingConnectionConfig.timeoutSeconds,
        format: .number.grouping(.never)
      )
      .textFieldStyle(.plain)
      .inputStyle()
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
        "e.g., Production DB, Development Server", text: $viewModel.editingConnectionConfig.name
      )
      .textFieldStyle(.plain)
      .inputStyle()
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
        .padding(Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .fill(Color.inputBackground)
        )
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(Color.border, lineWidth: 1)
        )
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
      Picker(selection: connectionStringSSLModeBinding) {
        ForEach(SSLMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onChange(of: connectionStringSSLModeBinding.wrappedValue) { _, newMode in
        // Update the config when SSL mode changes
        viewModel.editingConnectionConfig.sslMode = newMode
        clearTestResult()
      }
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

      Toggle("", isOn: $viewModel.editingConnectionConfig.rememberConnection)
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
        Text(viewModel.editingConnectionConfig.protectionLevel.description)
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      Picker("", selection: $viewModel.editingConnectionConfig.protectionLevel) {
        ForEach(ConnectionProtectionLevel.allCases, id: \.self) { level in
          Label(level.displayName, systemImage: level.iconName).tag(level)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 160)
    }

    // Security Level (Safe Mode) Picker
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Security level")
          .font(.body)
        if let mode = viewModel.editingConnectionConfig.safeMode {
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

      Picker("", selection: $viewModel.editingConnectionConfig.safeMode) {
        Text("Use Global").tag(SafeMode?.none)
        ForEach(SafeMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(Optional(mode))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 130)
    }
  }
}
