//
//  ExplainNodeDetail.swift
//  Dblore
//
//  Inspector for the selected EXPLAIN node: conditions, output, and extra keys.
//

import SwiftUI

struct ExplainNodeDetail: View {
  let node: ExplainNode

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(ExplainNodeTitle.type(node))
            .font(.labelText)
            .foregroundStyle(Color.foreground)
          if let relation = ExplainNodeTitle.relation(node) {
            Text(relation)
              .font(.monoSmall)
              .foregroundStyle(Color.foregroundMuted)
              .textSelection(.enabled)
          }
        }

        if let filter = node.filter {
          section("Filter", text: filter)
        }
        if let indexCond = node.indexCond {
          section("Index Cond", text: indexCond)
        }
        if let hashCond = node.hashCond {
          section("Hash Cond", text: hashCond)
        }
        if let output = node.output, !output.isEmpty {
          section("Output", text: output.joined(separator: "\n"))
        }
        if !node.extras.isEmpty {
          extras
        }
        if node.filter == nil, node.indexCond == nil, node.hashCond == nil,
          node.output?.isEmpty != false, node.extras.isEmpty
        {
          Text("No filter, condition, or extra fields.")
            .font(.small)
            .foregroundStyle(Color.foregroundSubtle)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityLabel("Node details")
  }

  private func section(_ title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.smallest)
        .foregroundStyle(Color.foregroundSubtle)
      Text(text)
        .font(.monoSmall)
        .foregroundStyle(Color.foreground)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var extras: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Other")
        .font(.smallest)
        .foregroundStyle(Color.foregroundSubtle)
      ForEach(node.extras.keys.sorted(), id: \.self) { key in
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(key)
            .font(.smallest)
            .foregroundStyle(Color.foregroundMuted)
          Text(ExplainJSONText.string(node.extras[key] ?? .null))
            .font(.monoSmall)
            .foregroundStyle(Color.foreground)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}

enum ExplainJSONText {
  static func string(_ value: JSONValue) -> String {
    switch value {
    case .null:
      return "null"
    case .bool(let value):
      return value ? "true" : "false"
    case .number(let value):
      return ExplainMetricText.number(value)
    case .string(let value):
      return value
    case .array(let values):
      return values.map { string($0) }.joined(separator: ", ")
    case .object(let fields):
      return fields.keys.sorted().map { key in
        "\(key): \(string(fields[key] ?? .null))"
      }.joined(separator: "\n")
    }
  }
}
