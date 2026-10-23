//
//  ConnectionFormContent+Scripts.swift
//  Dblore
//
//  Scripts section of the connection form: pre-connect, password command and post-disconnect
//  scripts picked from the Application Scripts folder (see ConnectionScriptRunner), their
//  timeout, and a button that opens the folder.
//

import AppKit
import SwiftUI

extension ConnectionFormContent {
  func scriptsSection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      scriptPicker(
        "Before connecting", summary: "Runs first; a failure stops the connect",
        selection: $connectionConfig.preConnectScript)
      if connectionConfig.databaseType.capabilities.usesPassword {
        scriptPicker(
          "Password command", summary: "Its first line is the password, never saved",
          selection: $connectionConfig.passwordCommandScript)
      }
      scriptPicker(
        "After disconnecting",
        summary: "Runs once the connection is closed, or when it fails after the first script",
        selection: $connectionConfig.postDisconnectScript)

      FormField(label: "Script timeout (seconds, 1 to 300)") {
        TextField(
          "\(ConnectionScriptRunner.defaultTimeout)",
          value: $connectionConfig.scriptTimeoutSeconds, format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .numberInputCapsuleStyle()
        .frame(width: 120)
      }

      Text(Self.scriptsHelp)
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)

      Button("Open Scripts Folder", action: openScriptsFolder)
        .buttonStyle(FilledSecondaryButtonStyle())
    }
    .onAppear(perform: refreshScriptNames)
    // Scripts added in Finder show up when the app comes back
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      refreshScriptNames()
    }
  }

  static var scriptsHelp: String {
    let bundle = Bundle.main.bundleIdentifier ?? "ace.thi.Dblore"
    return
      "Put scripts in ~/Library/Application Scripts/\(bundle). Each script gets the host, port, "
      + "user and database as arguments. The password command prints the password on its first "
      + "line. A script that times out keeps running: Dblore cannot stop it. Arguments come "
      + "from the connection: quote them in your script and pass -- before them to other "
      + "commands."
  }

  /// None, every script of the folder, and the current name when it is no longer there.
  private func scriptPicker(
    _ title: String, summary: String, selection: Binding<String?>
  ) -> some View {
    let current = selection.wrappedValue
    let missing = current.map { !availableScripts.contains($0) } ?? false
    let label = current.map { missing ? "\($0) (missing)" : $0 } ?? "None"
    return HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
        Text(summary)
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      Menu {
        Button("None") { selection.wrappedValue = nil }
        if !availableScripts.isEmpty { Divider() }
        ForEach(availableScripts, id: \.self) { name in
          Button(name) { selection.wrappedValue = name }
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Text(verbatim: label)
            .lineLimit(1)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .linkPointer()
      .fixedSize()
    }
  }

  func refreshScriptNames() {
    let names = ConnectionScriptRunner.app.availableNames()
    if names != availableScripts { availableScripts = names }
  }

  /// Opens the scripts folder in Finder, created first when missing.
  private func openScriptsFolder() {
    guard
      let folder = (try? ConnectionScriptRunner.applicationScriptsFolder(create: true))
        ?? (try? ConnectionScriptRunner.applicationScriptsFolder())
    else { return }
    NSWorkspace.shared.open(folder)
    refreshScriptNames()
  }
}
