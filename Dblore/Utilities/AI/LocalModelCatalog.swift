// LocalModelCatalog.swift
// Curated catalog of on-device MLX models (4-bit, Apache-2.0), sorted by size ascending

import Foundation

nonisolated struct LocalModel: Identifiable, Sendable, Equatable {
  nonisolated enum Tier: String, Sendable, CaseIterable {
    case tiny
    case balanced
    case best
  }

  /// One file of the pinned revision: plain name, size in bytes and lowercase hex SHA-256.
  nonisolated struct File: Sendable, Equatable {
    let name: String
    let size: Int64
    let sha256: String
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
  /// Files the download fetches from the pinned revision, each checked by size and SHA-256;
  /// `scripts/pin-local-model.py` prints them.
  let files: [File]
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
      note: "Fastest, good for simple queries",
      files: [
        .init(
          name: "chat_template.jinja", size: 7_755,
          sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
        .init(
          name: "config.json", size: 3_113,
          sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
        .init(
          name: "model.safetensors", size: 1_722_271_785,
          sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
        .init(
          name: "model.safetensors.index.json", size: 81_722,
          sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
        .init(
          name: "preprocessor_config.json", size: 390,
          sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        .init(
          name: "processor_config.json", size: 1_300,
          sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        .init(
          name: "tokenizer.json", size: 19_989_343,
          sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        .init(
          name: "tokenizer_config.json", size: 1_139,
          sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        .init(
          name: "video_preprocessor_config.json", size: 385,
          sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        .init(
          name: "vocab.json", size: 6_722_759,
          sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
      ]
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
      note: "Balanced speed and quality",
      files: [
        .init(
          name: "chat_template.jinja", size: 7_756,
          sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
        .init(
          name: "config.json", size: 3_366,
          sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
        .init(
          name: "model.safetensors", size: 3_034_300_695,
          sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
        .init(
          name: "model.safetensors.index.json", size: 101_944,
          sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
        .init(
          name: "preprocessor_config.json", size: 390,
          sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        .init(
          name: "processor_config.json", size: 1_300,
          sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        .init(
          name: "tokenizer.json", size: 19_989_343,
          sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        .init(
          name: "tokenizer_config.json", size: 1_139,
          sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        .init(
          name: "video_preprocessor_config.json", size: 385,
          sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        .init(
          name: "vocab.json", size: 6_722_759,
          sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
      ]
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
      note: "Best quality",
      files: [
        .init(
          name: "chat_template.jinja", size: 7_756,
          sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
        .init(
          name: "config.json", size: 3_331,
          sha256: "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8"),
        .init(
          name: "model-00001-of-00002.safetensors", size: 5_349_771_222,
          sha256: "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd"),
        .init(
          name: "model-00002-of-00002.safetensors", size: 600_449_850,
          sha256: "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d"),
        .init(
          name: "model.safetensors.index.json", size: 123_592,
          sha256: "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e"),
        .init(
          name: "preprocessor_config.json", size: 390,
          sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        .init(
          name: "processor_config.json", size: 1_300,
          sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        .init(
          name: "tokenizer.json", size: 19_989_343,
          sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        .init(
          name: "tokenizer_config.json", size: 1_139,
          sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        .init(
          name: "video_preprocessor_config.json", size: 385,
          sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        .init(
          name: "vocab.json", size: 6_722_759,
          sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
      ]
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
      note: "Alternative to Qwen3.5 9B, larger and slower",
      files: [
        .init(
          name: "chat_template.jinja", size: 17_466,
          sha256: "36e3a42e5cf14cd0020e72d92e1fdd9970f59b82170e421f0cbe1bb42bead3f0"),
        .init(
          name: "config.json", size: 5_415,
          sha256: "fbc1c1cb48ed86ec98482b2d41f5a03d3991aba74b7c29a93d430761e6518a38"),
        .init(
          name: "generation_config.json", size: 260,
          sha256: "a8349d9bd64cc5841297fcb5002f0fdc4749c473c8f1b10ea337f9ce4ee7014e"),
        .init(
          name: "model-00001-of-00002.safetensors", size: 5_351_756_584,
          sha256: "0d58feed0c98a69c07317b4481aeae5ab2785f12a496ea96ab24c4842808de78"),
        .init(
          name: "model-00002-of-00002.safetensors", size: 1_389_282_927,
          sha256: "5b00a1bcb596ce6e827b4cdea6ecf2a0f35bb01306eb87c1ea4b3bcde36c7755"),
        .init(
          name: "model.safetensors.index.json", size: 135_329,
          sha256: "9ac99e7a6cf3e4d40eb8df01644fe9c04036ace94f3389df35db9d9449758516"),
        .init(
          name: "processor_config.json", size: 868,
          sha256: "016a1db9c4f41ea0c61919c46855ea5e7c45c6e4ae4bfbedfb5b6bed79a2fe92"),
        .init(
          name: "tokenizer.json", size: 32_169_626,
          sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        .init(
          name: "tokenizer_config.json", size: 2_719,
          sha256: "fc1384a911d2c9860ac07bc3ceafff20bff26695991744b7dbe5e1e4522bfa57"),
      ]
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
