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
            rowBadge
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
    .frame(width: 440, height: 560)
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
    .modalBarPadding(vertical: Spacing.sm)
  }

  private var showsFormatOptions: Bool {
    let format = options.format
    return format.offersHeaderToggle || format.offersNullAsEmpty || format.offersWrap
      || format.offersLineBreakToSpace || format.offersFormulaSanitize || format.offersEncoding
      || format.offersQuote || format.offersLineBreak || format.offersJsonPretty
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
        optionToggle(
          options.format.headerToggleTitle, isOn: $options.includeHeader,
          help: options.format == .sqlInsert
            ? "Each INSERT lists the column names."
            : "The first row lists the column names.")
      }
      if options.format.offersNullAsEmpty {
        optionToggle(
          "Convert NULL to empty", isOn: $options.nullAsEmpty,
          help: options.format == .sqlInsert
            ? "NULL cells become an empty string. Turn off to write NULL."
            : "NULL cells become an empty field. Turn off to write the text NULL.")
      }
      if options.format.offersLineBreakToSpace {
        optionToggle(
          "Convert line break to space", isOn: $options.convertLineBreaksToSpace,
          help: "Replaces a line break inside a cell with a space.")
      }
      if options.format.offersFormulaSanitize {
        optionToggle(
          "Sanitize formula-like values", isOn: $options.sanitizeFormulas,
          help:
            "Prefixes text that starts with =, +, -, @, or a tab so a spreadsheet does not run it as a formula."
        )
      }
      if options.format.offersWrap {
        optionToggle(
          "Wrap long text", isOn: $options.wrapText,
          help: "Keeps the full cell text. Turn off to cut long cells with an ellipsis.")
      }
      if options.format.offersJsonPretty {
        optionToggle(
          "Pretty print", isOn: $options.jsonPretty,
          help: "Indents the JSON. Turn off for one line.")
        optionToggle(
          "Include null", isOn: $options.jsonIncludeNull,
          help: "Keeps keys whose value is null. Turn off to omit them.")
        optionToggle(
          "Preserve all values as string", isOn: $options.jsonValuesAsString,
          help: "Writes numbers, booleans, and null as text. Null becomes the text NULL.")
      }
      if options.format.offersEncoding {
        optionPicker(
          "Encoding", selection: $options.encoding,
          help:
            "UTF-16 LE includes a byte order mark. Windows-1252 drops characters it cannot store."
        ) {
          ForEach(ExportEncoding.allCases) { encoding in
            Text(encoding.title).tag(encoding)
          }
        }
      }
      if options.format.offersQuote {
        optionPicker(
          "Quote", selection: $options.quote,
          help:
            "Quote if needed wraps a field with a comma, a quote, or a line break. Never can split a field."
        ) {
          ForEach(ExportQuote.allCases) { quote in
            Text(quote.title).tag(quote)
          }
        }
      }
      if options.format.offersLineBreak {
        optionPicker(
          "Line break", selection: $options.lineBreak,
          help: "Record separators and line breaks inside fields use this ending."
        ) {
          ForEach(ExportLineBreak.allCases) { lineBreak in
            Text(lineBreak.title).tag(lineBreak)
          }
        }
      }
    }
  }

  private func optionToggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
    Toggle(title, isOn: isOn)
      .toggleStyle(.checkbox)
      .font(.bodyText)
      .help(help)
  }

  private func optionPicker<Selection: Hashable>(
    _ title: String, selection: Binding<Selection>, help: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.bodyText)
        .foregroundColor(.foreground)
      Spacer(minLength: Spacing.sm)
      Picker(title, selection: selection, content: content)
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
    .help(help)
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
      Button("Reset to Default") {
        options = ExportOptions(format: options.format)
      }
      .buttonStyle(GhostButtonStyle())
      Spacer()
      Button("Cancel", action: onCancel)
        .buttonStyle(GhostButtonStyle())
      Button("Export", action: export)
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

  private var rowBadge: some View {
    let count = result.rows.count
    let tint = rowTint(ExportRowScale.level(for: count))
    return HStack(spacing: Spacing.xs) {
      Text(count.formatted())
        .font(.labelText.weight(.semibold))
        .monospacedDigit()
      Text(rowCaption(count))
        .font(.small)
    }
    .foregroundColor(tint)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
    .background(tint.opacity(0.15), in: Capsule())
    .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
  }

  private func rowCaption(_ count: Int) -> String {
    let noun = count == 1 ? "row" : "rows"
    if result.wasLimited {
      return "loaded \(noun) to export"
    }
    return "\(noun) to export"
  }

  private func rowTint(_ level: ExportRowScale) -> Color {
    switch level {
    case .modest: .success
    case .large: .warning
    case .huge: .destructive
    }
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
