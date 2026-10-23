//
//  MongoAggregationOptionsPanel.swift
//  Dblore
//
//  Aggregate options of the MongoDB Aggregations section, shown below its header: Collation as a
//  mongosh field and maxTimeMS as a number field. It edits the builder's options directly; the
//  header names an option that does not parse, as it blocks Copy, Run and the other actions.
//  Preview documents sets the global stage preview size (`AppSettings.mongoPreviewDocumentCount`).
//

import SwiftUI

struct MongoAggregationOptionsPanel: View {
  @Bindable var builder: AggregationBuilderModel
  @Bindable private var appSettings = AppSettings.shared

  /// Width of the number field
  private static let numberWidth: CGFloat = 80

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.xs) {
      GridRow(alignment: .top) {
        label("Collation")
          .frame(height: MongoQueryField.styledLineHeight)
        MongoQueryField(
          text: $builder.options.collation,
          placeholder: #"e.g. {locale: "en", strength: 2}"#
        )
        .inputStyle()
        .frame(maxWidth: .infinity)
        .help("Collation of the aggregate: string comparison rules such as locale and strength")
        .accessibilityLabel("Collation")
      }
      GridRow(alignment: .center) {
        label("maxTimeMS")
        HStack(spacing: Spacing.sm) {
          TextField("Default", text: $builder.options.maxTimeMS)
            .textFieldStyle(.plain)
            .numberInputCapsuleStyle()
            .frame(width: Self.numberWidth)
            .help("Server time limit in milliseconds, capped by the statement timeout")
            .accessibilityLabel("maxTimeMS")
          Spacer(minLength: 0)
        }
      }
      GridRow(alignment: .center) {
        label("Preview documents")
        HStack(spacing: Spacing.sm) {
          CapsulePickerMenu(title: appSettings.mongoPreviewDocumentCount.formatted()) {
            Picker("", selection: $appSettings.mongoPreviewDocumentCount) {
              ForEach(AppSettings.mongoPreviewDocumentCounts, id: \.self) { count in
                Text(count.formatted()).tag(count)
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }
          .help("Documents each stage preview shows, for every collection")
          .accessibilityLabel("Preview documents")
          Spacer(minLength: 0)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .fixedSize()
  }
}
