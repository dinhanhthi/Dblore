// LocalModelCatalog.swift
// Curated catalog of on-device MLX models (4-bit, Apache-2.0), sorted by size ascending

import Foundation

nonisolated struct LocalModel: Identifiable, Sendable, Equatable {
  nonisolated enum Tier: String, Sendable, CaseIterable {
    case tiny
    case balanced
    case best
  }

  let id: String
  let repoID: String
  /// Full commit SHA the download is pinned to; bump deliberately after reviewing the repo.
  let revision: String
  let displayName: String
  let tier: Tier
  let approxSizeBytes: Int64
  let minRAMBytes: Int64
  let license: String
  let note: String
}

nonisolated enum LocalModelCatalog {
  private static let gb: Int64 = 1_073_741_824

  /// Display order: smallest first. Sizes are the repo storage reported by Hugging Face.
  static let all: [LocalModel] = [
    LocalModel(
      id: "qwen2.5-coder-1.5b",
      repoID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
      revision: "b3252a2f97102b1fb1571fec2c9b27219a8536be",
      displayName: "Qwen2.5 Coder 1.5B (4-bit)",
      tier: .tiny,
      approxSizeBytes: 868_628_559,
      minRAMBytes: 8 * gb,
      license: "Apache-2.0",
      note: "Fastest, good for simple queries"
    ),
    LocalModel(
      id: "qwen3-4b-instruct-2507",
      repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
      revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
      displayName: "Qwen3 4B Instruct (4-bit)",
      tier: .balanced,
      approxSizeBytes: 2_274_445_071,
      minRAMBytes: 8 * gb,
      license: "Apache-2.0",
      note: "Balanced speed and quality"
    ),
    LocalModel(
      id: "omnisql-7b",
      repoID: "sazak/OmniSQL-7B-4bit-mlx",
      revision: "43986495330ae8a82349fc1f99909a52b8e070b3",
      displayName: "OmniSQL 7B (4-bit)",
      tier: .best,
      approxSizeBytes: 4_295_768_620,
      minRAMBytes: 16 * gb,
      license: "Apache-2.0",
      note: "SQL-tuned (trained mostly on SQLite dialect)"
    ),
  ]

  static func model(for id: String) -> LocalModel? {
    all.first { $0.id == id }
  }

  /// Largest model whose minimum RAM fits; nil when the Mac is below every minimum.
  static func recommended(forRAM ram: UInt64) -> LocalModel? {
    all.last { $0.minRAMBytes <= Int64(clamping: ram) }
  }
}
