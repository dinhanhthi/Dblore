//
//  ConnectionFormContent+Masking.swift
//  Dblore
//
//  Masking section of the connection form (SQL engines): the connection's column mask rules,
//  an add row that checks the pattern, and what masking does not cover
//

import SwiftUI

extension ColumnMaskRule.Style {
  var title: String {
    switch self {
    case .full: "Full"
    case .lastFour: "Last 4"
    case .email: "Email"
    case .null: "NULL"
    }
  }
}

extension ConnectionFormContent {
  static let maskingSummary =
    "Masking hides matching columns in Dblore's results, copies, exports, AI and MCP. It matches "
    + "column names, so a query that renames or computes a column is not masked. It is not "
    + "access control."

  static let maskingLimits = [
    "A rule change applies from the next query; open results are not re-run.",
    "Results saved earlier in a .sqlnb file keep their values.",
    "On DuckDB, a table.column rule matches that column in every table (DuckDB reports no "
      + "source table).",
    "Filters, sorting and Find in every table can still search a masked column.",
    "While a transaction is open, a table renamed by another session or by a function since "
      + "this connection last read it is matched by its old name until the transaction ends.",
    "SQL dumps and backups, MongoDB exports and backups, Copy Objects, Schema Compare and the "
      + "Data Rewind store keep real values.",
    "MongoDB is covered only by field name, in the grid, AI and MCP.",
  ]

  /// The rules (pattern, style, remove), the add row and the limits. The section card supplies
  /// the "Masking" title.
  @ViewBuilder
  func maskingSection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ForEach(Array(connectionConfig.maskRules.enumerated()), id: \.offset) { index, rule in
        HStack(spacing: Spacing.sm) {
          Text(verbatim: rule.pattern)
            .font(.body)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: Spacing.sm)
          maskStylePicker(rule.style) { style in
            guard connectionConfig.maskRules.indices.contains(index) else { return }
            connectionConfig.maskRules[index].style = style
          }
          Button {
            guard connectionConfig.maskRules.indices.contains(index) else { return }
            connectionConfig.maskRules.remove(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .help("Remove this rule")
          .accessibilityLabel("Remove the rule for \(rule.pattern)")
        }
      }

      HStack(spacing: Spacing.sm) {
        TextField("column, table.column or schema.table.column", text: $newMaskPattern)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .onSubmit(addMaskRule)
        maskStylePicker(newMaskStyle) { newMaskStyle = $0 }
        Button("Add", action: addMaskRule)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(
            newMaskPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || connectionConfig.maskRules.count >= ColumnMaskRule.maxRules)
      }
      .onChange(of: newMaskPattern) { _, _ in maskPatternError = nil }
      if let maskPatternError {
        Text(maskPatternError)
          .font(.caption)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(Self.maskingSummary)
        ForEach(Self.maskingLimits, id: \.self) { limit in
          Text(verbatim: "\u{2022} \(limit)")
        }
      }
      .font(.caption)
      .foregroundColor(.foregroundMuted)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func maskStylePicker(
    _ style: ColumnMaskRule.Style, onSelect: @escaping (ColumnMaskRule.Style) -> Void
  ) -> some View {
    CapsuleDropdown(
      title: style.title, accessibilityLabel: "Mask style",
      options: ColumnMaskRule.Style.allCases, optionTitle: \.title,
      isSelected: { $0 == style }, onSelect: onSelect
    )
    .fixedSize()
  }

  /// Adds the typed rule when `ColumnMaskRule` accepts its pattern and no rule has it; otherwise
  /// says why under the field and adds nothing.
  func addMaskRule() {
    do {
      let rule = try ColumnMaskRule(pattern: newMaskPattern, style: newMaskStyle)
      guard
        !connectionConfig.maskRules.contains(where: {
          $0.normalizedPattern == rule.normalizedPattern
        })
      else {
        maskPatternError = "This column already has a rule."
        return
      }
      guard connectionConfig.maskRules.count < ColumnMaskRule.maxRules else {
        maskPatternError = "A connection has at most \(ColumnMaskRule.maxRules) rules."
        return
      }
      connectionConfig.maskRules.append(rule)
      newMaskPattern = ""
      maskPatternError = nil
    } catch {
      maskPatternError = Self.maskPatternMessage(error)
    }
  }

  static func maskPatternMessage(_ error: Error) -> String {
    switch error as? ColumnMaskRule.PatternError {
    case .empty: "Enter a column name."
    case .tooLong: "A pattern has at most \(ColumnMaskRule.patternLimit) characters."
    case .tooManySegments, .emptySegment: "Use column, table.column or schema.table.column."
    case .wildcardColumn: "* can stand for a schema or a table, not for the column."
    case .partialWildcard: "* must be a whole name, as in *.email."
    case nil: error.localizedDescription
    }
  }

  /// The rules the form starts from: its own and the saved row's (`keepingSavedMaskRules`, read
  /// as with Remember on: a live connection masks with the saved row's rules either way), so a
  /// saved removal never drops a rule the form did not show. Run with `seedAIFields`.
  func seedMaskRules() {
    var probe = connectionConfig
    probe.rememberConnection = true
    let seed = WorkspaceManager.keepingSavedMaskRules(probe).maskRules
    maskSeed = seed
    if connectionConfig.maskRules != seed { connectionConfig.maskRules = seed }
    newMaskPattern = ""
    maskPatternError = nil
  }

  /// True when the user changed the rules since the form was seeded: the save then drops from
  /// the saved row's rules only the ones the user removed (`keepingSavedMaskRules(_:seed:)`)
  /// instead of adding all of them to the form's
  var maskRulesEdited: Bool {
    connectionConfig.maskRules != maskSeed
  }
}
