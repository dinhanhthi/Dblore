import SwiftUI

/// Build Join Query: the picked tables in join order, each with its join kind, checked columns
/// and filter rows, and the SELECT that joins them on their foreign keys. Open in Query Tab puts
/// it in a new query tab; nothing runs here.
struct JoinBuilderSheet: View {
  let workspaceManager: WorkspaceManager
  @Bindable var model: JoinBuilderModel
  @Binding var isPresented: Bool

  private static let columnGrid = [GridItem(.adaptive(minimum: 160), alignment: .leading)]

  var body: some View {
    let preview = model.preview
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Build Join Query", titleIcon: "point.3.connected.trianglepath.dotted",
        onClose: { isPresented = false })
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          ForEach($model.entries) { $entry in
            entrySection($entry)
          }
          addSection
          previewSection(preview)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      footer(preview)
    }
    .background(Color.cardBackground)
  }

  private func footer(_ preview: Result<JoinQueryBuilder.Query, Error>) -> some View {
    GenericModalFooter {
      Spacer()
      Button("Cancel") { isPresented = false }
        .buttonStyle(FilledSecondaryButtonStyle())
      Button("Open in Query Tab") {
        guard case .success(let query) = preview else { return }
        workspaceManager.newSQLFile(content: query.sql)
        // The ER diagram covers the tabs: leave it so the new query shows
        workspaceManager.hideSchemaVisualizer()
        isPresented = false
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled((try? preview.get()) == nil)
    }
  }

  // MARK: - Tables

  private func entrySection(_ entry: Binding<JoinBuilderModel.Entry>) -> some View {
    let index = model.entries.firstIndex { $0.id == entry.wrappedValue.id } ?? 0
    let table = entry.wrappedValue.table
    return SettingsGroupCard(
      title: "\(index + 1). \(model.spansSchemas ? table.qualifiedName : table.name)",
      accessory: {
        HStack(spacing: Spacing.xs) {
          if index > 0 {
            Button {
              model.moveUp(entry.wrappedValue.id)
            } label: {
              Image(systemName: "arrow.up")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Join earlier")
            .accessibilityLabel("Move \(table.name) up")
          }
          Button {
            model.remove(entry.wrappedValue.id)
          } label: {
            Image(systemName: "minus")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .help("Remove table")
          .accessibilityLabel("Remove \(table.name)")
        }
      },
      content: {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if index == 0 {
            Text("The first table is the FROM table; the tables below join it.")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          } else {
            HStack(spacing: Spacing.sm) {
              Text("Join")
                .font(.bodyText)
                .foregroundColor(.foreground)
              CapsuleTabPicker(
                selection: entry.kind, tabs: JoinQueryBuilder.JoinKind.allCases, height: 28
              ) { kind in
                CapsuleTabLabel(text: kind.title, isSelected: entry.wrappedValue.kind == kind)
              }
              .fitsContent()
            }
          }
          columnsGrid(entry)
          Text("Filter")
            .font(.bodyText)
            .foregroundColor(.foreground)
          FilterConditionsEditor(
            conditions: entry.conditions, columns: table.columns.map(\.name), onSubmit: {})
        }
      })
  }

  private func columnsGrid(_ entry: Binding<JoinBuilderModel.Entry>) -> some View {
    let columns = entry.wrappedValue.table.columns
    return VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Columns")
        .font(.bodyText)
        .foregroundColor(.foreground)
      if columns.isEmpty {
        Text("No columns listed for this table.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        LazyVGrid(columns: Self.columnGrid, alignment: .leading, spacing: Spacing.xs) {
          ForEach(columns) { column in
            Toggle(
              column.name,
              isOn: Binding(
                get: { entry.wrappedValue.selected.contains(column.name) },
                set: { isOn in
                  if isOn {
                    entry.wrappedValue.selected.insert(column.name)
                  } else {
                    entry.wrappedValue.selected.remove(column.name)
                  }
                })
            )
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .truncationMode(.middle)
          }
        }
      }
    }
  }

  private var addSection: some View {
    HStack(spacing: Spacing.sm) {
      CapsuleDropdown(
        title: "Add Table", accessibilityLabel: "Add table", options: model.tableNames,
        optionTitle: { model.spansSchemas ? "\($0.schema).\($0.name)" : $0.name },
        isSelected: { _ in false }, onSelect: model.add)
      Spacer()
      Text("No column checked selects every column.")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
  }

  // MARK: - Preview

  @ViewBuilder
  private func previewSection(_ preview: Result<JoinQueryBuilder.Query, Error>) -> some View {
    SettingsGroupCard(title: "SQL") {
      switch preview {
      case .success(let query):
        VStack(alignment: .leading, spacing: Spacing.sm) {
          SQLCodeWell(sql: query.sql, dialect: model.dialect)
            .frame(height: 220)
          let junctions = query.tables.filter { !$0.isPicked }.map(\.table.name)
          if !junctions.isEmpty {
            Label(
              "Joined via \(junctions.joined(separator: ", ")) to link the picked tables.",
              systemImage: "link"
            )
            .font(.small)
            .foregroundColor(.foregroundMuted)
          }
        }
      case .failure(let error):
        Text(error.localizedDescription)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
