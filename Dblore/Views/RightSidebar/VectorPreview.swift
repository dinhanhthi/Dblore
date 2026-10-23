//
//  VectorPreview.swift
//  Dblore
//
//  Cell Value viewer for a pgvector value: dimension, L2 norm, min, max and the leading values.
//

import SwiftUI

struct VectorPreview: View {
  let vector: VectorValue
  /// The value's own text, copied whole.
  let text: String

  @State private var isCopied = false

  var body: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          detail("Dimension", vector.dimension.formatted())
          if let nonZeroCount = vector.nonZeroCount {
            detail("Non-zero", nonZeroCount.formatted())
          }
          detail("Norm", Self.number(vector.norm))
        }

        HStack(alignment: .top, spacing: Spacing.lg) {
          detail("Min", Self.number(vector.minimum))
          detail("Max", Self.number(vector.maximum))
        }

        HStack {
          Text(
            vector.dimension > vector.leadingValues.count
              ? "First \(vector.leadingValues.count) values" : "Values"
          )
          .font(.caption)
          .foregroundColor(.foregroundSubtle)

          Spacer()

          FloatingPanelButton(
            icon: isCopied ? "checkmark" : "doc.on.doc",
            helpText: "Copy Vector",
            useSymbolEffect: true,
            action: copyVector
          )
        }

        Text(vector.leadingValues.map(Self.number).joined(separator: ", "))
          .font(.mono)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(Spacing.sm)
          .background(Color.tableHeaderBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private static func number(_ value: Double) -> String {
    String(format: "%.6g", value)
  }

  private func detail(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
    }
  }

  private func copyVector() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    isCopied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
    }
  }
}
