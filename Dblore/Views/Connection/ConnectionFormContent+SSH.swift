//
//  ConnectionFormContent+SSH.swift
//  Dblore
//
//  SSH tunnel section of the connection form
//

import AppKit
import SwiftUI

// MARK: - SSH Tunnel Section

extension ConnectionFormContent {

  /// Toggle plus bastion fields. Shown only for engines that support SSH (`SSHFormDraft`).
  @ViewBuilder
  func sshTunnelSection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Connect through SSH")
            .font(.body)
          Text("Reach the database through a bastion host")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }

        Spacer()

        Toggle("", isOn: $sshDraft.enabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(.accent)
          .scaleEffect(0.8)
      }

      if sshDraft.enabled {
        sshTunnelFields()
      }
    }
  }

  @ViewBuilder
  private func sshTunnelFields() -> some View {
    HStack(spacing: Spacing.md) {
      FormField(label: "SSH host") {
        TextField("bastion.example.com", text: $sshDraft.host)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }

      FormField(label: "Port") {
        TextField("22", value: $sshDraft.port, format: .number.grouping(.never))
          .textFieldStyle(.plain)
          .numberInputCapsuleStyle()
          .frame(width: 80)
      }
    }

    FormField(label: "SSH username") {
      TextField("username", text: $sshDraft.username)
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
    }

    sshAuthMethodMenu()

    switch sshDraft.authMethod {
    case .password:
      FormField(label: "SSH password") {
        SecureField(sshPasswordPlaceholder, text: $sshDraft.password)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }
    case .privateKey:
      sshPrivateKeyFields()
    }

    if sshDraft.needsSecretForNewBastion(storedMethod: sshStoredMethod, original: sshOriginalConfig)
    {
      Text(SSHFormDraft.newBastionSecretHint)
        .font(.caption)
        .foregroundColor(.warning)
    }
  }

  /// A saved password is not shown; leaving the field empty keeps it.
  private var sshPasswordPlaceholder: String {
    sshDraft.canUseStoredCredential(usableSSHStoredMethod)
      ? "Leave empty to keep the saved password" : "password"
  }

  private func sshAuthMethodMenu() -> some View {
    FormField(label: "Authentication") {
      Menu {
        ForEach([SSHTunnelConfig.AuthMethod.password, .privateKey], id: \.self) { method in
          Button(Self.sshAuthTitle(method)) { sshDraft.authMethod = method }
        }
      } label: {
        HStack {
          Text(Self.sshAuthTitle(sshDraft.authMethod))
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
  }

  static func sshAuthTitle(_ method: SSHTunnelConfig.AuthMethod) -> String {
    switch method {
    case .password: "Password"
    case .privateKey: "Private key"
    }
  }

  @ViewBuilder
  private func sshPrivateKeyFields() -> some View {
    let summary = sshKeySummary
    FormField(label: "Private key (OpenSSH)") {
      HStack(spacing: Spacing.sm) {
        Button(summary == nil ? "Choose Key File…" : "Replace Key File…") {
          chooseSSHKeyFile()
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(sshDraft.isImportingKey)
        if sshDraft.isImportingKey {
          ProgressView()
            .controlSize(.small)
          Text("Reading key…").font(.caption).foregroundColor(.foregroundMuted)
        }
      }
    }

    if sshDraft.needsPassphrase {
      FormField(label: "Key passphrase") {
        HStack(spacing: Spacing.sm) {
          SecureField("Passphrase", text: $sshDraft.passphrase)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
            .onSubmit { unlockSSHKey() }
          Button("Unlock") { unlockSSHKey() }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(sshDraft.passphrase.isEmpty || sshDraft.isImportingKey)
        }
      }
    }

    if let summary {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "checkmark.seal.fill")
          .foregroundColor(.success)
        VStack(alignment: .leading, spacing: 2) {
          if let algorithm = summary.algorithm {
            Text(algorithm)
              .foregroundColor(.foreground)
          }
          Text(summary.fingerprint)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.foregroundMuted)
            .textSelection(.enabled)
        }
      }
      .font(.caption)
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(Color.success.opacity(0.1))
      )
    }

    if summary != nil || sshDraft.needsPassphrase {
      Button("Remove", role: .destructive) { removeSSHKey() }
        .buttonStyle(SecondaryButtonStyle())
    }

    if let keyError = sshDraft.keyError {
      Text(keyError)
        .font(.caption)
        .foregroundColor(.warning)
    }
  }

  /// The imported key, else the key already stored for this connection.
  private var sshKeySummary: (algorithm: String?, fingerprint: String)? {
    if let key = sshDraft.importedKey { return (key.algorithm, key.fingerprint) }
    guard let fingerprint = sshDraft.storedKeyFingerprint else { return nil }
    return (sshDraft.storedKeyAlgorithm, fingerprint)
  }

  private func unlockSSHKey() {
    guard !sshDraft.passphrase.isEmpty, !sshDraft.isImportingKey else { return }
    Task { @MainActor in await retrySSHKeyImport() }
  }

  /// Hidden files are shown so `~/.ssh` is reachable; key files often have no extension.
  private func chooseSSHKeyFile() {
    guard !SessionManager.isRunningAsTestHost else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Choose"
    panel.message = "Choose an OpenSSH private key (for example id_ed25519)"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let read = await Task.detached(priority: .userInitiated) {
          Result { try Self.readSSHKeyFile(at: url) }
        }.value
        switch read {
        case .success(let data):
          await importSSHKey(data: data, passphrase: nil)
        case .failure:
          sshDraft.keyError = "Choose a readable private key file smaller than 1 MB."
        }
      }
    }
  }

  /// Reads the picked file once. Key bytes are passed on to the import and not kept here. Only
  /// regular files: a FIFO or device could block the read or never end.
  nonisolated static func readSSHKeyFile(at url: URL) throws -> Data {
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 1_048_577) ?? Data()
    guard !data.isEmpty, data.count <= 1_048_576 else {
      throw CocoaError(.fileReadTooLarge)
    }
    return data
  }
}
