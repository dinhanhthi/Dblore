// AggregationTemplateTests.swift
// The Wizard's aggregation templates: every template, filled with sample values (plain names,
// names that need quoting, "$" paths), builds stages the aggregation builder accepts.

import Foundation
import Testing

@testable import Dblore

@Suite("Aggregation templates")
@MainActor
struct AggregationTemplateTests {
  @Test("Every template filled with sample values builds valid stages")
  func templatesBuildValidStages() {
    let samples = [
      { (field: AggregationTemplate.Field) in field.placeholder },
      { _ in "order \"total\" é" },
      { _ in "$items.price" },
    ]
    #expect(!AggregationTemplate.all.isEmpty)
    for template in AggregationTemplate.all {
      #expect((1...3).contains(template.fields.count), "\(template.id)")
      for sample in samples {
        let stages = template.build(template.fields.map(sample))
        #expect(!stages.isEmpty, "\(template.id)")
        for stage in stages {
          let result = AggregationBuilderModel.value(
            of: .init(id: UUID(), operator: stage.operator, body: stage.body, isEnabled: true))
          if case .failure(let error) = result {
            Issue.record("\(template.id) \(stage.operator) \(stage.body): \(error.message)")
          }
        }
      }
    }
  }
}
