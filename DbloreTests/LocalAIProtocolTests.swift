import Foundation
import Testing

@testable import Dblore

/// Guards the protocol v1 wire contract between the app and the On-device AI plugin: field names,
/// discriminators and the event cap. The golden lines pin the wire, so a field rename can't
/// silently break an installed plugin of an earlier build.
@Suite struct LocalAIProtocolTests {
  typealias Request = LocalAIProtocol.Request
  typealias Event = LocalAIProtocol.Event

  /// Every request kind and its exact wire line (sorted keys)
  private static let requests: [(Request, String)] = [
    (Request(id: "1", kind: .hello), #"{"id":"1","type":"hello"}"#),
    (Request(id: "2", kind: .gpuProbe), #"{"id":"2","type":"gpuProbe"}"#),
    (
      Request(
        id: "3",
        kind: .generate(
          .init(
            modelID: "qwen3.5-2b", modelPath: "/Models/qwen3.5-2b", system: "You write SQL.",
            messages: [
              .init(role: .user, text: "Count users"), .init(role: .assistant, text: "OK"),
            ],
            maxTokens: 512, temperature: 0, context: .init(enableThinking: false)))),
      #"{"context":{"enable_thinking":false},"id":"3","maxTokens":512,"messages":[{"role":"user","text":"Count users"},{"role":"assistant","text":"OK"}],"modelID":"qwen3.5-2b","modelPath":"/Models/qwen3.5-2b","system":"You write SQL.","temperature":0,"type":"generate"}"#
    ),
    (Request(id: "4", kind: .cancel(target: "3")), #"{"id":"4","target":"3","type":"cancel"}"#),
    (
      Request(id: "5", kind: .unload(modelID: "qwen3.5-2b")),
      #"{"id":"5","modelID":"qwen3.5-2b","type":"unload"}"#
    ),
  ]

  /// Every event kind and its exact wire line, including the plugin's current hello, gpu and error
  private static let events: [(String, Event)] = [
    (
      #"{"event":"hello","id":"1","protocol":1,"version":"1.0.0"}"#,
      Event(id: "1", kind: .hello(protocol: 1, version: "1.0.0"))
    ),
    (
      #"{"device":"Device(gpu, 0)","event":"gpu","id":"2","ok":true,"value":12}"#,
      Event(id: "2", kind: .gpu(.ok(device: "Device(gpu, 0)", value: 12)))
    ),
    (
      #"{"error":"No Metal device","event":"gpu","id":"2","ok":false}"#,
      Event(id: "2", kind: .gpu(.failed(error: "No Metal device")))
    ),
    (#"{"event":"loading","id":"3"}"#, Event(id: "3", kind: .loading)),
    (#"{"event":"loaded","id":"3"}"#, Event(id: "3", kind: .loaded)),
    (
      #"{"chunk":"SELECT 1","event":"text","id":"3"}"#,
      Event(id: "3", kind: .text(chunk: "SELECT 1"))
    ),
    (#"{"event":"done","id":"3"}"#, Event(id: "3", kind: .done)),
    (#"{"event":"cancelled","id":"3"}"#, Event(id: "3", kind: .cancelled)),
    (#"{"event":"unloaded","id":"5","ok":false}"#, Event(id: "5", kind: .unloaded(ok: false))),
    (
      #"{"code":"invalid","event":"error","message":"The request is not a JSON object"}"#,
      Event(id: nil, kind: .error(code: .invalid, message: "The request is not a JSON object"))
    ),
  ]

  @Test(arguments: requests)
  func requestRoundTripsThroughItsWireLine(_ request: Request, _ line: String) throws {
    #expect(String(decoding: try LocalAIProtocol.encode(request), as: UTF8.self) == line)
    #expect(LocalAIProtocol.decodeRequest(Data(line.utf8)) == request)
  }

  @Test(arguments: events)
  func eventRoundTripsThroughItsWireLine(_ line: String, _ event: Event) throws {
    #expect(LocalAIProtocol.decodeEvent(Data(line.utf8)) == event)
    #expect(String(decoding: try LocalAIProtocol.encode(event), as: UTF8.self) == line)
  }

  /// The app reads an event of at most 1 MiB; a valid event one byte over is dropped.
  @Test func eventOverTheSizeCapIsDropped() {
    let overhead = #"{"chunk":"","event":"text","id":"1"}"#.utf8.count
    func event(bytes: Int) -> Data {
      let chunk = String(repeating: "a", count: bytes - overhead)
      return Data(#"{"chunk":"\#(chunk)","event":"text","id":"1"}"#.utf8)
    }
    #expect(LocalAIProtocol.decodeEvent(event(bytes: LocalAIProtocol.maxEventBytes)) != nil)
    #expect(LocalAIProtocol.decodeEvent(event(bytes: LocalAIProtocol.maxEventBytes + 1)) == nil)
  }

  @Test(arguments: [#"[{"event":"done","id":"1"}]"#, #"{"event":"nope","id":"1"}"#])
  func eventThatIsNotAKnownObjectIsDropped(_ line: String) {
    #expect(LocalAIProtocol.decodeEvent(Data(line.utf8)) == nil)
  }
}
