import Foundation
import Testing

@testable import Dblore

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {

  private let gb: UInt64 = 1_073_741_824

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

  @Test("one entry per tier")
  func oneEntryPerTier() {
    let tiers = LocalModelCatalog.all.map(\.tier)
    #expect(tiers.count == 3)
    #expect(Set(tiers) == [.tiny, .balanced, .best])
  }

  @Test("sorted by size ascending")
  func sortedBySize() {
    let sizes = LocalModelCatalog.all.map(\.approxSizeBytes)
    #expect(sizes == sizes.sorted())
    #expect(LocalModelCatalog.all.map(\.tier) == [.tiny, .balanced, .best])
  }

  @Test("model(for:) finds entries by id")
  func lookup() {
    let first = LocalModelCatalog.all[0]
    #expect(LocalModelCatalog.model(for: first.id) == first)
    #expect(LocalModelCatalog.model(for: "nope") == nil)
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
}
