//
//  RightSidebarView.swift
//  SQLNotebook
//

import SwiftUI

struct RightSidebarView: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(spacing: 0) {
      // Header
      sidebarHeader

      Divider()

      // Content
      if let content = viewModel.rightSidebarContent {
        // ConnectionFormContent handles its own layout with ScrollView and fixed footer
        if case .connectionForm = content {
          contentView(for: content)
        } else {
          // Other content types use ScrollView wrapper
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              contentView(for: content)
                .padding(Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }
      } else {
        emptyState
      }
    }
    .frame(width: sidebarWidth)
    .background(Color.cardBackground)
    .overlay(alignment: .leading) {
      Divider()
    }
    .animation(.easeInOut(duration: 0.2), value: sidebarWidth)
  }

  private var sidebarHeader: some View {
    HStack {
      Text(headerTitle)
        .font(.subheading)
        .foregroundColor(.foreground)

      Spacer()

      Button(action: { viewModel.closeSidebar() }) {
        Image(systemName: "xmark")
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle())
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cellBackground)
  }

  private var headerTitle: String {
    guard let content = viewModel.rightSidebarContent else {
      return "Details"
    }

    switch content {
    case .jsonViewer:
      return "JSON Viewer"
    case .cellInfo:
      return "Cell Value"
    case .connectionDetails:
      return "Connection"
    case .connectionForm:
      return "Database Connection"
    }
  }

  private var sidebarWidth: CGFloat {
    guard let content = viewModel.rightSidebarContent else {
      return ComponentSize.sidebarWidth
    }

    switch content {
    case .connectionForm:
      return 450
    default:
      return ComponentSize.sidebarWidth
    }
  }

  @ViewBuilder
  private func contentView(for content: SidebarContent) -> some View {
    // Using explicit switch to help type inference
    switch content {
    case .jsonViewer(let json, let path):
      JSONViewerContent(json: json, path: path)
    case .cellInfo(let columnName, let columnType, let value):
      CellInfoContent(columnName: columnName, columnType: columnType, value: value)
    case .connectionDetails:
        ConnectionInfoContent(config: viewModel.notebook.connectionConfig)
    case .connectionForm:
      ConnectionFormContent(viewModel: viewModel)
    }
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "sidebar.right")
        .font(.system(size: 32))
        .foregroundColor(.foregroundSubtle)

      Text("JSON data will be displayed here when a cell's output is selected.")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }
}

// MARK: - JSON Viewer

struct JSONViewerContent: View {
  let json: String
  let path: String
  @State private var isPrettyPrinted = true
  @State private var searchText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Path info
      Text(path)
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      // Toolbar
      HStack {
        Toggle("Pretty Print", isOn: $isPrettyPrinted)
          .toggleStyle(.switch)
          .controlSize(.small)

        Spacer()

        Button(action: copyToClipboard) {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(GhostButtonStyle())
      }

      // JSON content
      ScrollView(.horizontal, showsIndicators: false) {
        Text(formattedJSON)
          .font(.monoSmall)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
      }
      .padding(Spacing.sm)
      .background(Color.cellBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
  }

  private var formattedJSON: String {
    if isPrettyPrinted {
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let prettyData = try? JSONSerialization.data(
          withJSONObject: object, options: .prettyPrinted),
        let prettyString = String(data: prettyData, encoding: .utf8)
      else {
        return json
      }
      return prettyString
    }
    return json
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(formattedJSON, forType: .string)
  }
}

// MARK: - Cell Info Content

struct CellInfoContent: View {
  let columnName: String
  let columnType: String
  let value: CellValue

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Column info
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Column")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)

        Text("\(columnName) (\(columnType))")
          .font(.mono)
          .foregroundColor(.foreground)
      }

      Divider()

      // Value type
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Type")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)

        Text(valueTypeName)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
      }

      Divider()

      // Full value
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Value")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          Button(action: copyToClipboard) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(GhostButtonStyle())
        }

        ScrollView {
          Text(value.fullString)
            .font(.mono)
            .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
            .italic(value.isNull)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(Spacing.sm)
        .background(Color.cellBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
    }
  }

  private var valueTypeName: String {
    switch value {
    case .string: return "String"
    case .int: return "Integer"
    case .double: return "Double"
    case .bool: return "Boolean"
    case .null: return "NULL"
    case .json: return "JSON"
    case .date: return "Date"
    case .data: return "Binary Data"
    }
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value.fullString, forType: .string)
  }
}

// MARK: - Connection Info Content

struct ConnectionInfoContent: View {
  let config: ConnectionConfig?

  var body: some View {
    if let config {
      VStack(alignment: .leading, spacing: Spacing.md) {
        infoRow(label: "Host", value: config.host)
        infoRow(label: "Port", value: String(config.port))
        infoRow(label: "Database", value: config.database)
        infoRow(label: "Username", value: config.username)
        infoRow(label: "SSL Mode", value: config.sslMode.displayName)
      }
    } else {
      Text("No connection configured")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
  }

  private func infoRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
    }
  }
}

// MARK: - Connection Form Content

struct ConnectionFormContent: View {
  @Bindable var viewModel: NotebookViewModel

  @State private var isTesting = false
  @State private var testResult: TestResult?
  @State private var isConnecting = false
  @State private var inputMode: ConnectionInputMode = .form
  @State private var connectionString: String = ""
  @State private var parseError: String?
  @State private var isPasswordVisible = false
  @State private var connectionStringSSLMode: SSLMode = .prefer

  enum TestResult {
    case success
    case failure(String)
  }

  enum ConnectionInputMode: String, CaseIterable {
    case form = "Form"
    case connectionString = "Connection String"
  }

  var body: some View {
    VStack(spacing: 0) {
      // Main scrollable content
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          // Input Mode Picker with Sliding Animation
          customTabPicker()
            .onChange(of: inputMode) { _, newMode in
              parseError = nil
              testResult = nil
              if newMode == .connectionString {
                // Generate connection string from current config
                connectionString = generateConnectionString()
                // Sync SSL mode state with current config
                connectionStringSSLMode = viewModel.editingConnectionConfig.sslMode
              }
            }

          if inputMode == .form {
            formFields()
          } else {
            connectionStringFields()
          }
        }
        .padding(Spacing.lg)
      }

      // Fixed Footer at bottom
      VStack(spacing: 0) {
        // Status messages below buttons
        if let error = parseError {
          errorView(error)
        }

        if let result = testResult {
          testResultView(result)
        }

        // Action Buttons
        HStack(spacing: Spacing.md) {
          Button(action: testConnection) {
            HStack(spacing: Spacing.sm) {
              if isTesting {
                ProgressView()
                  .scaleEffect(0.7)
                  .frame(width: 14, height: 14)
              }
              Text("Test Connection")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(isTesting || !isFormValid)

          Button(action: connect) {
            HStack(spacing: Spacing.sm) {
              if isConnecting {
                ProgressView()
                  .scaleEffect(0.7)
                  .frame(width: 14, height: 14)
              }
              Text("Connect")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(isConnecting || !isFormValid)
        }.padding(.top, Spacing.md)
      }.padding(Spacing.md)
    }
  }

  private var isFormValid: Bool {
    if inputMode == .connectionString {
      return !connectionString.isEmpty
    }
    return !viewModel.editingConnectionConfig.host.isEmpty
      && !viewModel.editingConnectionConfig.database.isEmpty
      && !viewModel.editingConnectionConfig.username.isEmpty
  }

  @ViewBuilder
  private func customTabPicker() -> some View {
    let selectedIndex = ConnectionInputMode.allCases.firstIndex(of: inputMode) ?? 0

    ZStack {
      // Background
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.inputBackground)
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(Color.border, lineWidth: 1)
        )

      // Content with padding
      GeometryReader { geometry in
        let inset: CGFloat = 3
        let availableWidth = geometry.size.width - (inset * 2)
        let tabWidth = availableWidth / CGFloat(ConnectionInputMode.allCases.count)

        ZStack(alignment: .leading) {
          // Sliding indicator
          RoundedRectangle(cornerRadius: CornerRadius.md - 2)
            .fill(Color.accentColor)
            .frame(width: tabWidth, height: geometry.size.height - (inset * 2))
            .offset(x: inset + CGFloat(selectedIndex) * tabWidth)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: inputMode)

          // Tab buttons
          HStack(spacing: 0) {
            ForEach(ConnectionInputMode.allCases, id: \.self) { mode in
              Button(action: {
                withAnimation {
                  inputMode = mode
                }
              }) {
                Text(mode.rawValue)
                  .font(.body)
                  .fontWeight(inputMode == mode ? .semibold : .regular)
                  .foregroundColor(inputMode == mode ? .white : .foreground)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .contentShape(Rectangle())
              }
              .buttonStyle(PlainButtonStyle())
            }
          }
        }
      }
    }
    .frame(height: 32)
  }

  @ViewBuilder
  private func formFields() -> some View {
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
        if isPasswordVisible {
          TextField("password", text: $viewModel.editingConnectionConfig.password)
            .textFieldStyle(.plain)
        } else {
          SecureField("password", text: $viewModel.editingConnectionConfig.password)
            .textFieldStyle(.plain)
        }

        Button(action: { isPasswordVisible.toggle() }) {
          Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
            .foregroundColor(.foregroundMuted)
            .frame(width: 20, height: 20)
        }
        .buttonStyle(PlainButtonStyle())
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
  }

  @ViewBuilder
  private func connectionStringFields() -> some View {
    FormField(label: "Connection String") {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        TextEditor(text: $connectionString)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 80)
          .scrollContentBackground(.hidden)
          .padding(Spacing.sm)
          .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
              .fill(Color.inputBackground)
          )
          .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
              .stroke(Color.border, lineWidth: 1)
          )
          .onChange(of: connectionString) { _, newValue in
            parseError = nil
            testResult = nil
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
      Picker(selection: $connectionStringSSLMode) {
        ForEach(SSLMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onChange(of: connectionStringSSLMode) { _, newMode in
        // Update the config when SSL mode changes
        viewModel.editingConnectionConfig.sslMode = newMode
        testResult = nil
      }
    }
  }

  private func generateConnectionString() -> String {
    let config = viewModel.editingConnectionConfig
    var components = URLComponents()
    components.scheme = "postgresql"
    components.user = config.username
    components.password = config.password.isEmpty ? nil : config.password
    components.host = config.host
    components.port = config.port
    components.path = "/\(config.database)"
    components.queryItems = [URLQueryItem(name: "sslmode", value: config.sslMode.rawValue)]

    return components.url?.absoluteString ?? ""
  }

  private func parseConnectionString(_ connectionStr: String) {
    // Support both postgresql:// and postgres:// schemes
    let normalizedStr = connectionStr.replacingOccurrences(of: "postgres://", with: "postgresql://")

    guard let url = URL(string: normalizedStr),
      let scheme = url.scheme,
      scheme == "postgresql" || scheme == "postgres"
    else {
      parseError = "Invalid connection string format"
      return
    }

    guard let host = url.host else {
      parseError = "Missing host in connection string"
      return
    }

    let port = url.port ?? 5432
    let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let username = url.user ?? ""
    let password = url.password ?? ""

    // Parse SSL mode from query parameters
    var sslMode: SSLMode = .prefer
    var hasExplicitSSLMode = false
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    {
      for item in queryItems {
        if item.name == "sslmode", let value = item.value {
          sslMode = SSLMode(rawValue: value) ?? .prefer
          hasExplicitSSLMode = true
        }
      }
    }

    // Smart default: Detect cloud database providers and require SSL
    if !hasExplicitSSLMode {
      let hostLower = host.lowercased()
      if hostLower.contains("supabase.com") || hostLower.contains("aws")
        || hostLower.contains("azure") || hostLower.contains("gcp") || hostLower.contains("cloud")
      {
        sslMode = .require
      }
    }

    if database.isEmpty {
      parseError = "Missing database name in connection string"
      return
    }

    if username.isEmpty {
      parseError = "Missing username in connection string"
      return
    }

    // Update the config
    viewModel.editingConnectionConfig.host = host
    viewModel.editingConnectionConfig.port = port
    viewModel.editingConnectionConfig.database = database
    viewModel.editingConnectionConfig.username = username
    viewModel.editingConnectionConfig.password = password
    viewModel.editingConnectionConfig.sslMode = sslMode

    // Sync the state for the SSL mode picker
    connectionStringSSLMode = sslMode

    parseError = nil
  }

  @ViewBuilder
  private func errorView(_ message: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text(message)
        .foregroundColor(.warning)
    }
    .font(.caption)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.warning.opacity(0.1))
    )
  }

  @ViewBuilder
  private func testResultView(_ result: TestResult) -> some View {
    HStack(spacing: Spacing.sm) {
      switch result {
      case .success:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.success)
        Text("Connection successful!")
          .foregroundColor(.success)
      case .failure(let message):
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.destructive)
        Text(message)
          .foregroundColor(.destructive)
      }
    }
    .font(.caption)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(result.isSuccess ? Color.success.opacity(0.1) : Color.destructive.opacity(0.1))
    )
  }

  private func testConnection() {
    isTesting = true
    testResult = nil

    Task {
      let success = await viewModel.testConnection()

      await MainActor.run {
        isTesting = false
        testResult = success ? .success : .failure("Connection failed. Check your credentials.")
      }
    }
  }

  private func connect() {
    isConnecting = true

    Task {
      do {
        try await viewModel.connect()
        await MainActor.run {
          isConnecting = false
          viewModel.closeSidebar()
        }
      } catch {
        await MainActor.run {
          isConnecting = false
          testResult = .failure(error.localizedDescription)
        }
      }
    }
  }
}

extension ConnectionFormContent.TestResult {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}

// MARK: - Form Field

struct FormField<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      content
    }
  }
}

#Preview("Empty State") {
  HStack {
    Spacer()
    RightSidebarView(viewModel: NotebookViewModel())
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Connection - Not Configured") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .connectionDetails

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Connection Form") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .connectionForm

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Connection - Connected") {
  let viewModel = NotebookViewModel()
  viewModel.notebook.connectionConfig = ConnectionConfig(
    host: "db.example.com",
    port: 5432,
    database: "my_database",
    username: "admin_user",
    password: "secret123",
    sslMode: .require
  )
  viewModel.rightSidebarContent = .connectionDetails

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("JSON Viewer") {
  let viewModel = NotebookViewModel()
  let jsonData = """
    {
      "user": {
        "id": 456,
        "name": "Jane Smith",
        "profile": {
          "bio": "Software engineer passionate about databases",
          "location": "San Francisco, CA",
          "website": "https://janesmith.dev"
        },
        "preferences": {
          "theme": "dark",
          "notifications": true,
          "language": "en-US"
        }
      },
      "metadata": {
        "created_at": "2024-01-15T10:30:00Z",
        "updated_at": "2024-03-20T14:45:00Z",
        "version": 3
      }
    }
    """
  viewModel.rightSidebarContent = .jsonViewer(json: jsonData, path: "users.details")

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Cell Info - Long Text") {
  let viewModel = NotebookViewModel()
  let longText = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
    """
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "description",
    columnType: "TEXT",
    value: .string(longText)
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
