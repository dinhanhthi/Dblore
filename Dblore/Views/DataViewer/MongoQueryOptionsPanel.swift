//
//  MongoQueryOptionsPanel.swift
//  Dblore
//
//  Query options of the MongoDB Documents bar, shown below the filter row: Project, Sort,
//  Collation and Hint as mongosh fields, Skip, Limit and maxTimeMS as number fields. It edits
//  the bar's draft; the bar applies it with the filter and shows the error naming a bad option.
//

import SwiftUI

struct MongoQueryOptionsPanel: View {
  @Binding var options: MongoQueryOptions
  /// The shown collection, for field name completion
  let collection: String?
  /// The workspace's autocomplete source; nil = no completion
  var fieldSource: SQLAutocompleteProvider?
  /// Return in any field (applies the filter and options)
  var onSubmit: () -> Void = {}

  /// Width of the number fields
  private static let numberWidth: CGFloat = 80

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.xs) {
      queryRow("Project", $options.project, "e.g. {name: 1, email: 1}", mode: .stage("$project"))
      queryRow("Sort", $options.sort, "e.g. {age: -1}", mode: .stage("$sort"))
      queryRow("Collation", $options.collation, #"e.g. {locale: "en", strength: 2}"#, mode: nil)
      // An index key document names fields as a sort does
      queryRow(
        "Hint", $options.hint, "Index name or key document, e.g. {age: 1}", mode: .stage("$sort"))
      GridRow(alignment: .center) {
        label("Skip")
        HStack(spacing: Spacing.sm) {
          numberField($options.skip, placeholder: "0")
          label("Limit")
          numberField($options.limit, placeholder: "None")
          label("maxTimeMS")
          numberField($options.maxTimeMS, placeholder: "Default")
            .help("Server time limit in milliseconds, capped by the statement timeout")
          Spacer(minLength: 0)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Rows

  /// A label and a mongosh field, the label level with the field's first line
  private func queryRow(
    _ title: String, _ text: Binding<String>, _ placeholder: String,
    mode: MongoshAutocompleteProvider.DocumentMode?
  ) -> some View {
    GridRow(alignment: .top) {
      label(title)
        .frame(height: MongoQueryField.styledLineHeight)
      MongoQueryField(
        text: text,
        placeholder: placeholder,
        autocompleteProvider: completion(mode),
        onSubmit: onSubmit
      )
      .inputStyle()
      .frame(maxWidth: .infinity)
    }
  }

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .fixedSize()
  }

  /// A whole number typed as text: `MongoQueryOptions.parsed()` checks it and names the option
  private func numberField(_ text: Binding<String>, placeholder: String) -> some View {
    TextField(placeholder, text: text)
      .textFieldStyle(.plain)
      .numberInputCapsuleStyle()
      .frame(width: Self.numberWidth)
      .onSubmit(onSubmit)
  }

  /// Field names of the collection for `mode`, nil for no completion
  private func completion(
    _ mode: MongoshAutocompleteProvider.DocumentMode?
  ) -> SQLAutocompleteProvider? {
    guard let mode, let collection, let fieldSource else { return nil }
    return MongoDocumentAutocompleteProvider(
      collection: collection, mode: mode, source: fieldSource)
  }
}
