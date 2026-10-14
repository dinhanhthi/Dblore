import Foundation
import Testing

@testable import Dblore

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {

  private let gb: UInt64 = 1_073_741_824

  @Test("catalog lists Qwen3.5 and Gemma 4 models, smallest first")
  func catalogModels() {
    #expect(
      LocalModelCatalog.all.map(\.id) == ["qwen3.5-2b", "qwen3.5-4b", "qwen3.5-9b", "gemma-4-12b"])
  }

  @Test("ids and repoIDs are unique")
  func uniqueIdentifiers() {
    let all = LocalModelCatalog.all
    #expect(Set(all.map(\.id)).count == all.count)
    #expect(Set(all.map(\.repoID)).count == all.count)
  }

  @Test("revisions are pinned to full commit SHAs")
  func revisionsArePinned() {
    for model in LocalModelCatalog.all {
      #expect(model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil)
    }
  }

  @Test("recommended is nil below the smallest minimum RAM")
  func recommendedBelowMinimum() {
    #expect(LocalModelCatalog.recommended(forRAM: 4 * gb) == nil)
    #expect(LocalModelCatalog.recommended(forRAM: 0) == nil)
  }

  @Test("recommended picks the largest tier that fits")
  func recommendedLargestFit() {
    #expect(LocalModelCatalog.recommended(forRAM: 8 * gb)?.tier == .balanced)
    #expect(LocalModelCatalog.recommended(forRAM: 12 * gb)?.tier == .balanced)
    #expect(LocalModelCatalog.recommended(forRAM: 16 * gb)?.tier == .best)
    #expect(LocalModelCatalog.recommended(forRAM: 64 * gb)?.tier == .best)
  }

  @Test("recommended picks the first model of the largest tier that fits")
  func recommendedFirstInTier() {
    #expect(LocalModelCatalog.recommended(forRAM: 8 * gb)?.id == "qwen3.5-4b")
    #expect(LocalModelCatalog.recommended(forRAM: 16 * gb)?.id == "qwen3.5-9b")
  }
}
