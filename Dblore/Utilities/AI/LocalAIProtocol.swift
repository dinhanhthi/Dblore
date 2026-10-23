// LocalAIProtocol.swift
// Protocol v1 between Dblore and the On-device AI plugin: one JSON object per request and per
// event. The plugin project compiles this same file (Plugins/LocalAI/project.yml), so it stays
// Foundation only and holds no app type.

import Foundation

/// Request and event types of protocol v1 and their JSON codec. A request names its kind in
/// `type` and an event in `event`; every request has an `id`, which its events echo. Event text
/// comes from the plugin and is untrusted.
nonisolated enum LocalAIProtocol {

  /// The version `dblore_localai_protocol()` returns and `hello` reports
  static let version = 1

  /// The largest event the app reads (1 MiB); a bigger one is dropped
  static let maxEventBytes = 1 << 20

  nonisolated struct Request: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
      case hello
      /// Runs one small op on the GPU, so a Metal failure never looks like a load failure
      case gpuProbe
      case generate(Generate)
      /// Cancels the request with the `target` id
      case cancel(target: String)
      /// Unloads that model, or every model when nil
      case unload(modelID: String?)
    }

    nonisolated struct Generate: Codable, Equatable, Sendable {
      nonisolated struct Message: Codable, Equatable, Sendable {
        nonisolated enum Role: String, Codable, Sendable { case user, assistant }
        let role: Role
        let text: String
      }

      /// Chat template options (`enable_thinking: false` turns thinking off for qwen3 models)
      nonisolated struct Context: Codable, Equatable, Sendable {
        let enableThinking: Bool

        enum CodingKeys: String, CodingKey { case enableThinking = "enable_thinking" }
      }

      let modelID: String
      let modelPath: String
      let system: String
      let messages: [Message]
      let maxTokens: Int
      let temperature: Float
      let context: Context?
    }

    let id: String
    let kind: Kind
  }

  nonisolated struct Event: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
      /// The plugin's protocol and bundle version
      case hello(protocol: Int, version: String)
      case gpu(GPUResult)
      case loading
      case loaded
      case text(chunk: String)
      case done
      case cancelled
      /// False while that model is loading or generating
      case unloaded(ok: Bool)
      case error(code: ErrorCode, message: String)
    }

    nonisolated enum GPUResult: Equatable, Sendable {
      case ok(device: String, value: Double)
      case failed(error: String)
    }

    nonisolated enum ErrorCode: String, Codable, Sendable { case busy, load, generate, invalid }

    /// The request's `id`; nil only when the request had none to echo
    let id: String?
    let kind: Kind
  }

  /// One request or event as compact JSON with sorted keys and unescaped slashes. Throws for a
  /// value JSON can't hold, such as a non-finite number.
  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  /// The request, or nil when `data` is not a JSON object of a known request kind
  static func decodeRequest(_ data: Data) -> Request? {
    try? JSONDecoder().decode(Request.self, from: data)
  }

  /// The event, or nil when `data` is over `maxEventBytes` or is not a JSON object of a known
  /// event kind
  static func decodeEvent(_ data: Data) -> Event? {
    guard data.count <= maxEventBytes else { return nil }
    return try? JSONDecoder().decode(Event.self, from: data)
  }
}

// MARK: - Wire format

nonisolated extension LocalAIProtocol.Request: Codable {
  private enum CodingKeys: String, CodingKey { case id, type, target, modelID }
  private enum Name: String, Codable { case hello, gpuProbe, generate, cancel, unload }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind: Kind
    switch try container.decode(Name.self, forKey: .type) {
    case .hello: kind = .hello
    case .gpuProbe: kind = .gpuProbe
    case .generate: kind = .generate(try Generate(from: decoder))
    case .cancel: kind = .cancel(target: try container.decode(String.self, forKey: .target))
    case .unload:
      kind = .unload(modelID: try container.decodeIfPresent(String.self, forKey: .modelID))
    }
    self.init(id: try container.decode(String.self, forKey: .id), kind: kind)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    switch kind {
    case .hello: try container.encode(Name.hello, forKey: .type)
    case .gpuProbe: try container.encode(Name.gpuProbe, forKey: .type)
    case .generate(let generate):
      try container.encode(Name.generate, forKey: .type)
      try generate.encode(to: encoder)  // its fields sit next to `id` and `type`
    case .cancel(let target):
      try container.encode(Name.cancel, forKey: .type)
      try container.encode(target, forKey: .target)
    case .unload(let modelID):
      try container.encode(Name.unload, forKey: .type)
      try container.encodeIfPresent(modelID, forKey: .modelID)
    }
  }
}

nonisolated extension LocalAIProtocol.Event: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, event, `protocol`, version, ok, device, value, error, chunk, code, message
  }
  private enum Name: String, Codable {
    case hello, gpu, loading, loaded, text, done, cancelled, unloaded, error
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func string(_ key: CodingKeys) throws -> String {
      try container.decode(String.self, forKey: key)
    }
    let kind: Kind
    switch try container.decode(Name.self, forKey: .event) {
    case .hello:
      kind = .hello(
        protocol: try container.decode(Int.self, forKey: .protocol), version: try string(.version))
    case .gpu:
      kind = .gpu(
        try container.decode(Bool.self, forKey: .ok)
          ? .ok(
            device: try string(.device), value: try container.decode(Double.self, forKey: .value))
          : .failed(error: try string(.error)))
    case .loading: kind = .loading
    case .loaded: kind = .loaded
    case .text: kind = .text(chunk: try string(.chunk))
    case .done: kind = .done
    case .cancelled: kind = .cancelled
    case .unloaded: kind = .unloaded(ok: try container.decode(Bool.self, forKey: .ok))
    case .error:
      kind = .error(
        code: try container.decode(ErrorCode.self, forKey: .code), message: try string(.message))
    }
    self.init(id: try container.decodeIfPresent(String.self, forKey: .id), kind: kind)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
    switch kind {
    case .hello(let version, let pluginVersion):
      try container.encode(Name.hello, forKey: .event)
      try container.encode(version, forKey: .protocol)
      try container.encode(pluginVersion, forKey: .version)
    case .gpu(.ok(let device, let value)):
      try container.encode(Name.gpu, forKey: .event)
      try container.encode(true, forKey: .ok)
      try container.encode(device, forKey: .device)
      try container.encode(value, forKey: .value)
    case .gpu(.failed(let error)):
      try container.encode(Name.gpu, forKey: .event)
      try container.encode(false, forKey: .ok)
      try container.encode(error, forKey: .error)
    case .loading: try container.encode(Name.loading, forKey: .event)
    case .loaded: try container.encode(Name.loaded, forKey: .event)
    case .text(let chunk):
      try container.encode(Name.text, forKey: .event)
      try container.encode(chunk, forKey: .chunk)
    case .done: try container.encode(Name.done, forKey: .event)
    case .cancelled: try container.encode(Name.cancelled, forKey: .event)
    case .unloaded(let ok):
      try container.encode(Name.unloaded, forKey: .event)
      try container.encode(ok, forKey: .ok)
    case .error(let code, let message):
      try container.encode(Name.error, forKey: .event)
      try container.encode(code, forKey: .code)
      try container.encode(message, forKey: .message)
    }
  }
}
