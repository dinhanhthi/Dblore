//
//  AISlashCommandsSettings.swift
//  Dblore
//
//  Settings > AI: the custom slash commands of the composer, with add, edit and delete.
//

import SwiftUI

struct AISlashCommandsCard: View {
  @Bindable var settings: AISettings

  /// The command in the editor: a new one (id not in the list) or a copy of a saved one
  @State private var editing: AICustomCommand?
  @State private var pendingDelete: AICustomCommand?

  private var commands: [AICustomCommand] { settings.configuration.customCommands }
  private var isFull: Bool { commands.count >= AISlashCommand.maxCustomCommands }

  var body: some View {
    SettingsGroupCard(title: "Slash commands") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        helpText(
          "Type / in the AI composer. Built-in: "
            + AISlashCommand.BuiltIn.allCases.map { "/" + $0.rawValue }.joined(separator: ", ")
            + " (Review and Optimize on SQL connections only).")
        helpText(
          "A custom command puts its template in the draft. {{query}}, {{selection}}, {{schema}} and {{error}} are filled in on this Mac, only for connections AI may read. You see the draft before it is sent."
        )
        if !commands.isEmpty {
          Divider()
          ForEach(commands) { command in
            row(command)
          }
        }
        if let editing {
          Divider()
          AISlashCommandEditor(
            command: editing, commands: commands,
            onSave: save, onCancel: { self.editing = nil })
        } else {
          Divider()
          HStack(spacing: Spacing.md) {
            Button("Add command") { editing = AICustomCommand(name: "", template: "") }
              .buttonStyle(FilledSecondaryButtonStyle())
              .disabled(isFull)
              .linkPointer()
            if isFull {
              helpText(AISlashCommand.ValidationError.tooManyCommands.message)
            }
          }
        }
      }
    }
    .confirmationDialog(
      "Delete /\(pendingDelete?.name ?? "")?",
      isPresented: Binding(
        get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible,
      presenting: pendingDelete
    ) { command in
      Button("Delete", role: .destructive) { delete(command) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The command and its template are removed.")
    }
  }

  private func row(_ command: AICustomCommand) -> some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(verbatim: "/" + command.name)
          .font(.mono)
          .foregroundColor(.foreground)
        Text(
          verbatim: command.template.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        )
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .lineLimit(1)
        .truncationMode(.tail)
      }
      Spacer(minLength: Spacing.sm)
      Button("Edit") { editing = command }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(editing != nil)
        .linkPointer()
      Button("Delete") { pendingDelete = command }
        .buttonStyle(DangerButtonStyle())
        .disabled(editing != nil)
        .linkPointer()
    }
  }

  /// Replaces the saved command of that id, else appends; refused when it does not validate
  private func save(_ command: AICustomCommand) {
    var list = commands
    guard AISlashCommand.validate(command, among: list) == nil else { return }
    if let index = list.firstIndex(where: { $0.id == command.id }) {
      list[index] = command
    } else {
      list.append(command)
    }
    settings.configuration.customCommands = list
    editing = nil
  }

  private func delete(_ command: AICustomCommand) {
    settings.configuration.customCommands.removeAll { $0.id == command.id }
  }

  private func helpText(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Name and template fields of one command, with its validation message and Save
private struct AISlashCommandEditor: View {
  let commands: [AICustomCommand]
  let onSave: (AICustomCommand) -> Void
  let onCancel: () -> Void

  @State private var command: AICustomCommand

  init(
    command: AICustomCommand, commands: [AICustomCommand],
    onSave: @escaping (AICustomCommand) -> Void, onCancel: @escaping () -> Void
  ) {
    self.commands = commands
    self.onSave = onSave
    self.onCancel = onCancel
    _command = State(initialValue: command)
  }

  private var error: AISlashCommand.ValidationError? {
    AISlashCommand.validate(command, among: commands)
  }

  /// An untouched new command shows no error yet
  private var shownError: AISlashCommand.ValidationError? {
    command.name.isEmpty && command.template.isEmpty ? nil : error
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      label("Name")
      HStack(spacing: Spacing.xs) {
        Text(verbatim: "/")
          .font(.mono)
          .foregroundColor(.foregroundMuted)
        TextField("my-command", text: $command.name)
          .textFieldStyle(.plain)
          .font(.mono)
          .autocorrectionDisabled()
          .inputStyle()
      }
      label("Template")
      TextEditor(text: $command.template)
        .font(.mono)
        .scrollContentBackground(.hidden)
        .frame(height: 96)
        .textAreaCapsuleStyle()
      Text(verbatim: counterText)
        .font(.small)
        .monospacedDigit()
        .foregroundColor(
          command.template.count > AISlashCommand.maxTemplateChars
            ? .destructive : .foregroundMuted
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
      if let shownError {
        Text(verbatim: shownError.message)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: Spacing.sm) {
        Spacer()
        Button("Cancel", action: onCancel)
          .buttonStyle(FilledSecondaryButtonStyle())
          .linkPointer()
        Button("Save") { onSave(command) }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(error != nil)
          .linkPointer()
      }
    }
  }

  /// "n / 4,000"
  private var counterText: String {
    let locale = Locale(identifier: "en_US")
    return "\(command.template.count.formatted(.number.locale(locale))) / "
      + AISlashCommand.maxTemplateChars.formatted(.number.locale(locale))
  }

  private func label(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foregroundMuted)
  }
}
