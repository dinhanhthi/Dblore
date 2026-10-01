// ResultExportSheet.swift
// Download options. The format picker opens on the menu item the user chose.
// Export writes a file. Nothing here is sent to the database.

import SwiftUI

struct ResultExportSheet: View {
  let result: CellResult
  var onExport: (ExportOptions) -> Void
  var onCancel: () -> Void

  @State private var options: ExportOptions
  @State private var estimate: ExportSizeEstimate
  @State private var confirmLarge = false

  init(
    result: CellResult, format: ExportFormat, onExport: @escaping (ExportOptions) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.result = result
    self.onExport = onExport
    self.onCancel = onCancel
    let initial = ExportOptions(format: format)
    _options = State(initialValue: initial)
    _estimate = State(initialValue: ExportSize.estimate(result: result, options: initial))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          sectionGroup {
            formatPicker
            Text(options.format.blurb)
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .fixedSize(horizontal: false, vertical: true)
            Text(rowSummary)
              .font(.small)
              .foregroundColor(.foregroundSubtle)
            sizeSummary
          }
          if showsFormatOptions {
            sectionGroup {
              formatOptions
            }
          }
          sectionGroup {
            sensitiveColumns
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 440, height: 520)
    .background(Color.appBackground)
    .onChange(of: options) { _, updated in
      estimate = ExportSize.estimate(result: result, options: updated)
    }
    .alert("Large export", isPresented: $confirmLarge) {
      Button("Cancel", role: .cancel) {}
      Button("Export anyway") { onExport(options) }
    } message: {
      Text(estimate.confirmMessage)
    }
  }

  private var header: some View {
    HStack {
      Text("Export")
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: onCancel) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
    }
    .modalBarPadding()
  }

  private var showsFormatOptions: Bool {
    options.format.offersHeaderToggle || options.format.offersNullAsEmpty
      || options.format.offersWrap
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.subheading.weight(.semibold))
      .foregroundColor(.foreground)
  }

  private func sectionGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      content()
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cardHeaderBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
        .stroke(Color.border, lineWidth: 1)
    )
  }

  private var formatPicker: some View {
    HStack(spacing: Spacing.sm) {
      sectionTitle("Format")
      Spacer(minLength: Spacing.sm)
      Picker("Format", selection: $options.format) {
        ForEach(ExportFormat.allCases) { format in
          Text(format.title).tag(format)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
    }
  }

  private var formatOptions: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionTitle("Options")
      if options.format.offersHeaderToggle {
        Toggle("Put field names in the first row", isOn: $options.includeHeader)
          .toggleStyle(.checkbox)
          .font(.bodyText)
          .help("The first row lists the column names.")
      }
      if options.format.offersNullAsEmpty {
        Toggle("Convert NULL to empty", isOn: $options.nullAsEmpty)
          .toggleStyle(.checkbox)
          .font(.bodyText)
          .help("NULL cells become an empty field. Turn off to write the text NULL.")
      }
      if options.format.offersWrap {
        Toggle("Wrap long text", isOn: $options.wrapText)
          .toggleStyle(.checkbox)
          .font(.bodyText)
          .help("Keeps the full cell text. Turn off to cut long cells with an ellipsis.")
      }
    }
  }

  private var sensitiveColumns: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionTitle("Sensitive columns")
      Text("Checked columns are written as \(ExportOptions.mask). You can select more than one.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .fixedSize(horizontal: false, vertical: true)
      if result.columns.isEmpty {
        Text("This result has no columns.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
            Toggle(isOn: redacted(index)) {
              HStack(spacing: Spacing.sm) {
                Text(columnTitle(column, index: index))
                  .font(.bodyText)
                  .foregroundColor(.foreground)
                  .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text(column.type)
                  .font(.monoSmall)
                  .foregroundColor(.foregroundSubtle)
                  .lineLimit(1)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Cancel", action: onCancel)
        .buttonStyle(GhostButtonStyle())
      Button("Export…", action: export)
        .buttonStyle(PrimaryButtonStyle())
    }
    .modalBarPadding()
  }

  private var sizeSummary: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(estimate.summary)
        .font(.small)
        .foregroundColor(estimate.isLarge ? .warning : .foregroundSubtle)
      if let warning = estimate.warning {
        Text(warning)
          .font(.small)
          .foregroundColor(.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func export() {
    if estimate.isLarge {
      confirmLarge = true
    } else {
      onExport(options)
    }
  }

  private var rowSummary: String {
    let count = result.rows.count
    let noun = count == 1 ? "row" : "rows"
    if result.wasLimited {
      return "\(count.formatted()) loaded \(noun) to export"
    }
    return "\(count.formatted()) \(noun) to export"
  }

  private func columnTitle(_ column: ColumnInfo, index: Int) -> String {
    column.name.isEmpty ? "Column \(index + 1)" : column.name
  }

  private func redacted(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { options.redactedColumns.contains(index) },
      set: { isOn in
        if isOn {
          options.redactedColumns.insert(index)
        } else {
          options.redactedColumns.remove(index)
        }
      })
  }
}
