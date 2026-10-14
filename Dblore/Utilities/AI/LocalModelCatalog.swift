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

  /// Display order: smallest first. Sizes are the total file size of the pinned revision on
  /// Hugging Face (Qwen3.5 and Gemma 4 repos also ship vision weights, skipped at load).
  static let all: [LocalModel] = [
    LocalModel(
      id: "qwen3.5-2b",
      repoID: "mlx-community/Qwen3.5-2B-MLX-4bit",
      revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
      displayName: "Qwen3.5 2B (4-bit)",
      tier: .tiny,
      approxSizeBytes: 1_749_083_534,
      minRAMBytes: 8 * gb,
      license: "Apache-2.0",
      note: "Fastest, good for simple queries"
    ),
    LocalModel(
      id: "qwen3.5-4b",
      repoID: "mlx-community/Qwen3.5-4B-MLX-4bit",
      revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
      displayName: "Qwen3.5 4B (4-bit)",
      tier: .balanced,
      approxSizeBytes: 3_061_132_920,
      minRAMBytes: 8 * gb,
      license: "Apache-2.0",
      note: "Balanced speed and quality"
    ),
    LocalModel(
      id: "qwen3.5-9b",
      repoID: "mlx-community/Qwen3.5-9B-MLX-4bit",
      revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631",
      displayName: "Qwen3.5 9B (4-bit)",
      tier: .best,
      approxSizeBytes: 5_977_074_591,
      minRAMBytes: 16 * gb,
      license: "Apache-2.0",
      note: "Best quality"
    ),
    LocalModel(
      id: "gemma-4-12b",
      repoID: "mlx-community/gemma-4-12B-it-4bit",
      revision: "73bcf09092aa277861d5a191b989b666f7f32e8f",
      displayName: "Gemma 4 12B (4-bit)",
      tier: .best,
      approxSizeBytes: 6_773_372_848,
      minRAMBytes: 16 * gb,
      license: "Apache-2.0",
      note: "Alternative to Qwen3.5 9B, larger and slower"
    ),
  ]

  static func model(for id: String) -> LocalModel? {
    all.first { $0.id == id }
  }

  /// First model of the largest tier whose minimum RAM fits; nil when the Mac is below every
  /// minimum.
  static func recommended(forRAM ram: UInt64) -> LocalModel? {
    let fitting = all.filter { $0.minRAMBytes <= Int64(clamping: ram) }
    guard let tier = fitting.last?.tier else { return nil }
    return fitting.first { $0.tier == tier }
  }
}
