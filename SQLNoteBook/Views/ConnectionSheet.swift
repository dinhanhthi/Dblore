//
//  ConnectionSheet.swift
//  SQLNotebook
//

import SwiftUI

struct ConnectionSheet: View {
    @Bindable var viewModel: NotebookViewModel
    @Binding var isPresented: Bool

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
            // Header
            HStack {
                Text("Database Connection")
                    .font(.heading)
                    .foregroundColor(.foreground)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.foregroundMuted)
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(Spacing.lg)

            Divider()

            // Form
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
            
            // Status messages (fixed at bottom)
            VStack(spacing: 0) {
                if let error = parseError {
                    errorView(error)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.md)
                }
                
                if let result = testResult {
                    testResultView(result)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.md)
                }
            }

            Divider()

            // Footer
            HStack(spacing: Spacing.md) {
                Button(action: testConnection) {
                    HStack(spacing: Spacing.sm) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Text("Test Connection")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isTesting || !isFormValid)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(SecondaryButtonStyle())
                
                Button(action: connect) {
                    HStack(spacing: Spacing.sm) {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Text("Connect")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isConnecting || !isFormValid)
            }
            .padding(Spacing.lg)
        }
        .frame(width: 450, height: 570)
        .background(Color.cardBackground)
    }

    private var isFormValid: Bool {
        if inputMode == .connectionString {
            return !connectionString.isEmpty
        }
        return !viewModel.editingConnectionConfig.host.isEmpty &&
        !viewModel.editingConnectionConfig.database.isEmpty &&
        !viewModel.editingConnectionConfig.username.isEmpty
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
                TextField("5432", value: $viewModel.editingConnectionConfig.port, format: .number.grouping(.never))
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
              (scheme == "postgresql" || scheme == "postgres") else {
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
           let queryItems = components.queryItems {
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
            if hostLower.contains("supabase.com") ||
               hostLower.contains("aws") ||
               hostLower.contains("azure") ||
               hostLower.contains("gcp") ||
               hostLower.contains("cloud") {
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
                    isPresented = false
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

extension ConnectionSheet.TestResult {
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

#Preview {
    ConnectionSheet(
        viewModel: NotebookViewModel(),
        isPresented: .constant(true)
    )
    .preferredColorScheme(.dark)
}
