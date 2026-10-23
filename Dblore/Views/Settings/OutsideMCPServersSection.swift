//
//  OutsideMCPServersSection.swift
//  Dblore
//
//  Settings > MCP > Outside MCP servers: add a server (name, URL, token), Test it (initialize
//  and tools/list), tick the tools the AI chat may call, and turn it on. A server is off when
//  added, so nothing is offered until one is added, tested, ticked and turned on. A ticked tool
//  whose description or schema changed shows as changed until it is ticked again. Server text
//  is untrusted: names, descriptions and errors are shown through `OutsideMCPText`.
//

import SwiftUI

/// The add form and the Test results. Tests run on the client actor; one per server at a time.
@MainActor @Observable
final class OutsideMCPServersModel {
  enum TestState: Equatable {
    case testing
    case failed(String)
    case listed([MCPClientTool])
  }

  var nameDraft = ""
  var urlDraft = ""
  var tokenDraft = ""
  private(set) var isAdding = false
  private(set) var addError: String?
  private(set) var tests: [UUID: TestState] = [:]

  let store: OutsideMCPServerStore
  @ObservationIgnored private var testTasks: [UUID: Task<Void, Never>] = [:]

  init(store: OutsideMCPServerStore = .shared) {
    self.store = store
  }

  /// Why the URL draft cannot be used; nil while empty or valid.
  var urlError: String? {
    guard !urlDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    do {
      _ = try MCPClient.endpoint(urlDraft)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  var canAdd: Bool {
    !isAdding && OutsideMCPServer.normalizedName(nameDraft) != nil
      && !urlDraft.trimmingCharacters(in: .whitespaces).isEmpty && urlError == nil
  }

  /// Adds the server (off), clears the form and tests it.
  func add() async {
    isAdding = true
    defer { isAdding = false }
    do {
      let server = try await store.add(name: nameDraft, url: urlDraft, token: tokenDraft)
      nameDraft = ""
      urlDraft = ""
      tokenDraft = ""
      addError = nil
      test(server)
    } catch {
      addError = error.localizedDescription
    }
  }

  func test(_ server: OutsideMCPServer) {
    testTasks[server.id]?.cancel()
    tests[server.id] = .testing
    let store = store
    testTasks[server.id] = Task { [weak self] in
      let outcome: TestState
      do {
        let token = try await store.token(for: server.id)
        let client = try MCPClient(
          url: try MCPClient.endpoint(server.url), token: token, serverID: server.id)
        _ = try await client.connect()
        outcome = .listed(try await client.listTools())
      } catch is CancellationError {
        return
      } catch {
        outcome = .failed(OutsideMCPText.display(error.localizedDescription, limit: 400))
      }
      guard !Task.isCancelled, let self else { return }
      tests[server.id] = outcome
      testTasks[server.id] = nil
    }
  }

  func remove(_ server: OutsideMCPServer) async {
    testTasks[server.id]?.cancel()
    testTasks[server.id] = nil
    tests[server.id] = nil
    await store.remove(id: server.id)
  }

  func setAllowed(_ tool: MCPClientTool, _ allowed: Bool, on server: OutsideMCPServer) {
    store.setAllowed(tool, allowed, for: server.id)
  }

  func setEnabled(_ isEnabled: Bool, for server: OutsideMCPServer) {
    store.setEnabled(isEnabled, for: server.id)
  }
}

struct OutsideMCPServersSection: View {
  @State private var model = OutsideMCPServersModel()

  var body: some View {
    SettingsGroupCard(title: "Outside MCP servers") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        note(
          "MCP servers whose tools the AI chat may call. A new server is off: test it, tick the tools to allow, then turn it on. Every call waits for your approval."
        )
        ForEach(model.store.servers) { server in
          Divider()
          serverRow(server)
        }
        Divider()
        addForm
        Divider()
        warning(
          "Tool results are untrusted data: a server can return text that tries to steer the AI. Add only servers you trust."
        )
      }
    }
  }

  private func serverRow(_ server: OutsideMCPServer) -> some View {
    let allowed = server.allowedTools.count
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      SettingsToggle(
        title: OutsideMCPText.display(server.name, limit: OutsideMCPServer.nameLimit),
        description: OutsideMCPText.display(server.url, limit: 120)
          + (allowed == 1 ? " · 1 tool allowed" : " · \(allowed) tools allowed"),
        isOn: Binding(
          get: { server.isEnabled },
          set: { model.setEnabled($0, for: server) }
        )
      )
      HStack(spacing: Spacing.sm) {
        Button("Test") { model.test(server) }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.tests[server.id] == .testing)
          .linkPointer()
        Button("Remove") {
          Task { await model.remove(server) }
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        .linkPointer()
        if model.tests[server.id] == .testing {
          ProgressView().controlSize(.small)
        }
      }
      testResult(server)
    }
  }

  @ViewBuilder
  private func testResult(_ server: OutsideMCPServer) -> some View {
    switch model.tests[server.id] {
    case .failed(let message):
      Text(verbatim: message)
        .font(.bodyText)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
    case .listed(let tools):
      if tools.isEmpty {
        note("The server lists no tools.")
      } else {
        note("Tick the tools the AI chat may call.")
        ForEach(tools, id: \.name) { tool in
          toolRow(tool, on: server)
        }
      }
    case .testing, nil:
      EmptyView()
    }
  }

  /// The full description: the client already capped it.
  private func toolRow(_ tool: MCPClientTool, on server: OutsideMCPServer) -> some View {
    let description = OutsideMCPText.display(tool.description, limit: .max)
    let state = OutsideMCPToolGate.state(of: tool, on: server)
    return Toggle(
      isOn: Binding(
        get: { state == .allowed },
        set: { model.setAllowed(tool, $0, on: server) }
      )
    ) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(verbatim: OutsideMCPText.display(tool.name, limit: MCPClient.maxToolNameLength))
          .font(.bodyText)
          .foregroundColor(.foreground)
        if state == .changed {
          Text("Changed: review and tick again")
            .font(.bodyText)
            .foregroundColor(.warning)
        }
        if !description.isEmpty {
          Text(verbatim: description)
            .font(.bodyText)
            .foregroundColor(.foregroundSubtle)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
    .toggleStyle(.checkbox)
  }

  private var addForm: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Add a server")
        .font(.bodyText)
        .foregroundColor(.foreground)
      TextField("Name", text: $model.nameDraft)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .autocorrectionDisabled()
        .inputStyle()
      TextField("https://mcp.example.com/mcp", text: $model.urlDraft)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .autocorrectionDisabled()
        .inputStyle()
      if let urlError = model.urlError {
        Text(urlError)
          .font(.bodyText)
          .foregroundColor(.destructive)
      }
      SecureField("Token (optional)", text: $model.tokenDraft)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .inputStyle()
      note(
        "The token is sent as a Bearer token and kept in the Keychain. Use https; plain http is allowed only for 127.0.0.1, ::1 and localhost. Redirects are not followed."
      )
      HStack(spacing: Spacing.sm) {
        Button("Add server") {
          Task { await model.add() }
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(!model.canAdd)
        .linkPointer()
        if model.isAdding {
          ProgressView().controlSize(.small)
        }
      }
      if let addError = model.addError {
        Text(addError)
          .font(.bodyText)
          .foregroundColor(.destructive)
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
  }

  /// Same look as a settings toggle warning.
  private func warning(_ text: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.bodyText)
      Text(text)
    }
    .font(.bodyText)
    .foregroundColor(.warning)
  }
}
