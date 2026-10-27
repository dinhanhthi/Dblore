//
//  FormatterSettingsSection.swift
//  Dblore
//
//  Settings > Editor > Formatter: the rules Format SQL uses, with a live preview of a small
//  fixed query (cheap enough to format on every change).
//

import SwiftUI

struct FormatterSettingsSection: View {
  @Bindable var appSettings: AppSettings

  static let description = "Format SQL uses these rules. The preview updates as you change them."

  /// Has a subquery (so indent shows), functions, a SELECT list and a WHERE line of 109
  /// characters (so 80 and 100 wrap differently and 120 keeps it whole)
  static let sampleQuery =
    "select c.name, count(o.id) as orders, sum(o.total) as revenue from customers c join (select customer_id, id, total from orders where status = 'paid') o on o.customer_id = c.id where c.country in ('FR', 'DE', 'US') and o.created_at >= now() - interval '30 days' and c.deleted_at is null group by c.name order by revenue desc"

  var body: some View {
    SettingsGroupCard(title: "Formatter") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text(Self.description)
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)

        row("Indent") {
          picker($appSettings.formatterIndent, FormatterIndent.allCases, title: \.title)
        }
        Divider()
        row("Keyword case") {
          picker($appSettings.formatterKeywordCase, WordCase.allCases, title: \.title)
        }
        Divider()
        row("Function case") {
          picker($appSettings.formatterFunctionCase, WordCase.allCases, title: \.title)
        }
        Divider()
        row("Comma position") {
          picker(
            $appSettings.formatterCommaPosition, SQLFormatter.Options.CommaPosition.allCases,
            title: \.title)
        }
        Divider()
        row("Line width") {
          picker($appSettings.formatterLineWidth, AppSettings.formatterLineWidths) {
            $0 == 0 ? "Off" : "\($0)"
          }
        }
        Divider()
        preview
      }
    }
  }

  private typealias WordCase = SQLFormatter.Options.WordCase

  private func row<Control: View>(
    _ title: String, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack {
      Text(title)
        .font(.bodyText)
        .foregroundColor(.foreground)
      Spacer()
      control()
        .accessibilityLabel(title)
    }
  }

  private func picker<Option: Hashable>(
    _ selection: Binding<Option>, _ options: [Option], title: @escaping (Option) -> String
  ) -> some View {
    CapsuleTabPicker(selection: selection, tabs: options, height: 28) { option in
      CapsuleTabLabel(text: title(option), isSelected: selection.wrappedValue == option)
    }
    .fitsContent()
  }

  /// The sample query formatted with the current rules. Lines keep their width (scroll sideways)
  /// so the line width choice shows as it will in the editor.
  private var preview: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Preview")
        .font(.bodyText)
        .foregroundColor(.foreground)
      ScrollView(.horizontal) {
        Text(SQLFormatter.format(Self.sampleQuery, options: appSettings.formatterOptions))
          .font(.monoSmall)
          .foregroundColor(.foreground)
          .fixedSize(horizontal: true, vertical: false)
          .textSelection(.enabled)
          .padding(Spacing.sm)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
    }
  }
}

extension SQLFormatter.Options.WordCase {
  var title: String {
    switch self {
    case .upper: "UPPER"
    case .lower: "lower"
    case .preserve: "Preserve"
    }
  }
}

extension SQLFormatter.Options.CommaPosition {
  var title: String {
    switch self {
    case .trailing: "Trailing"
    case .leading: "Leading"
    }
  }
}
