//
//  AttachedDatabasesSection.swift
//  Dblore
//
//  Attached databases of a SQLite connection: files attached under a schema name on every
//  connect (see `ConnectionConfig.validatedAttachedDatabases`). Shown for SQLite only.
//

import SwiftUI

extension ConnectionFormContent {
  /// One row per file (its schema name, its path, Remove), Add… while under the limit, and the
  /// warning a connect would show for each row it skips.
  func attachedDatabasesSection() -> some View {
    let attachments = connectionConfig.attachedDatabases
    let atLimit = attachments.count >= ConnectionConfig.attachedDatabasesLimit
    return FormField(label: "Attached databases") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
          attachedDatabaseRow(attachment, at: index)
        }

        ForEach(
          Array(connectionConfig.validatedAttachedDatabases().warnings.enumerated()), id: \.offset
        ) { _, warning in
          Text(warning)
            .font(.caption)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text("Each file is attached on connect, its tables read as name.table.")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)

        Button("Add…", action: addAttachedDatabase)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(atLimit)
          .help(
            atLimit
              ? "At most \(ConnectionConfig.attachedDatabasesLimit) attached databases"
              : "Choose a SQLite file to attach")
      }
    }
  }

  private func attachedDatabaseRow(_ attachment: AttachedDatabase, at index: Int) -> some View {
    HStack(spacing: Spacing.sm) {
      TextField("name", text: attachedNameBinding(at: index))
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .frame(width: 140)

      Text(attachment.path)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(attachment.path)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button("Remove") {
        guard connectionConfig.attachedDatabases.indices.contains(index) else { return }
        connectionConfig.attachedDatabases.remove(at: index)
      }
      .buttonStyle(FilledSecondaryButtonStyle())
    }
  }

  /// Checked index: a removed row's field may still write once while it loses focus
  private func attachedNameBinding(at index: Int) -> Binding<String> {
    Binding(
      get: {
        connectionConfig.attachedDatabases.indices.contains(index)
          ? connectionConfig.attachedDatabases[index].name : ""
      },
      set: { name in
        guard connectionConfig.attachedDatabases.indices.contains(index) else { return }
        connectionConfig.attachedDatabases[index].name = name
      })
  }

  /// Same panel and bookmark as the main file; the row is named after the file.
  private func addAttachedDatabase() {
    let panel = SQLiteFilePicker.openPanel()
    panel.message = "Choose a SQLite database file to attach"
    presentFilePanel(panel) { path, bookmark in
      let name = Self.attachmentName(
        forFile: path, taken: connectionConfig.attachedDatabases.map(\.name))
      connectionConfig.attachedDatabases.append(
        AttachedDatabase(name: name, path: path, bookmark: bookmark))
    }
  }

  /// The file name without its extension as an identifier (any other character becomes `_`, a
  /// leading digit gets a `_` before it), numbered until no row, `main` or `temp` uses it.
  static func attachmentName(forFile path: String, taken: [String]) -> String {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var base = String(
      stem.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
    if base.first?.isNumber ?? true { base = "_" + base }
    let used = Set((taken + ["main", "temp"]).map { $0.lowercased() })
    var name = base
    var number = 2
    while used.contains(name.lowercased()) {
      name = "\(base)_\(number)"
      number += 1
    }
    return name
  }
}
