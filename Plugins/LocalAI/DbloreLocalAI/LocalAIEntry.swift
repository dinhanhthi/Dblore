// LocalAIEntry.swift
// On-device AI plugin entry points. Dblore loads this bundle into its own process and calls the two
// C functions below (plain C types only): one protocol v1 request JSON object in, event JSON
// objects out through a callback. The types and codec are the app's LocalAIProtocol.swift.

import Foundation
import MLX

private typealias Event = LocalAIProtocol.Event

/// Protocol version of the request and event objects.
@_cdecl("dblore_localai_protocol")
public func dbloreLocalAIProtocol() -> Int32 { Int32(LocalAIProtocol.version) }

/// Answers the request JSON object `json` (UTF-8, NUL-terminated) by calling `emit` with `context`
/// and one event JSON object (UTF-8, NUL-terminated) per call, echoing the request `id` when there
/// is one. `hello`, `gpuProbe` and an invalid request get one event before this returns, on the
/// caller's thread; `generate` and `unload` answer later, from a Task on any thread, so `emit` and
/// `context` must stay valid for the life of the process. A `cancel` gets an event only when its
/// target is not running (see `LocalAIRequestHandler.cancel`). The string passed to `emit` is
/// valid only during that call.
@_cdecl("dblore_localai_request")
public func dbloreLocalAIRequest(
  _ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
  _ emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Void
) {
  respond(to: Data(bytes: json, count: strlen(json)), sink: EventSink(context: context, emit: emit))
}

/// Serves generate, cancel and unload with the shared engine, which loads a model only on the
/// first `generate`.
private let handler = LocalAIRequestHandler(engine: .shared)

/// The caller's callback and context, captured per request so a Task can answer later. The
/// caller keeps `context` alive and accepts calls from any thread (see `dbloreLocalAIRequest`).
private struct EventSink: @unchecked Sendable {
  let context: UnsafeMutableRawPointer?
  let emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Void

  func send(_ event: Event) {
    // An event that can't be encoded (e.g. a non-finite number) still answers with an error event.
    let data =
      (try? LocalAIProtocol.encode(event))
      ?? (try? LocalAIProtocol.encode(invalid("The event could not be encoded", id: event.id)))
      ?? Data(
        #"{"code":"invalid","event":"error","message":"The event could not be encoded"}"#.utf8)
    String(decoding: data, as: UTF8.self).withCString { emit(context, $0) }
  }
}

/// Marks this bundle's image for `Bundle(for:)`.
private final class LocalAIBundleToken {}

/// Answers one request, echoing its `id`: the handshake, GPU probe and invalid requests here,
/// generate, cancel and unload through the engine's request handler.
private func respond(to data: Data, sink: EventSink) {
  guard let request = LocalAIProtocol.decodeRequest(data) else {
    return sink.send(invalidRequest(data))
  }
  switch request.kind {
  case .hello: sink.send(Event(id: request.id, kind: hello()))
  case .gpuProbe: sink.send(Event(id: request.id, kind: gpuProbe()))
  case .generate(let generate): handler.generate(generate, id: request.id, emit: sink.send)
  case .cancel(let target): handler.cancel(target: target, id: request.id, emit: sink.send)
  case .unload(let modelID): handler.unload(modelID: modelID, id: request.id, emit: sink.send)
  }
}

/// The error for a request that doesn't decode, echoing its `id` when it is a string, so the app
/// can still match the answer to the request.
private func invalidRequest(_ data: Data) -> Event {
  guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    return invalid("The request is not a JSON object", id: nil)
  }
  let message =
    (object["type"] as? String).map { "Unknown or malformed request \"\($0)\"" }
    ?? "The request has no type"
  return invalid(message, id: object["id"] as? String)
}

/// Protocol handshake only. It never touches MLX, so a GPU failure can't look like a load failure.
/// The version is this plugin bundle's, not the app's.
private func hello() -> Event.Kind {
  let version =
    Bundle(for: LocalAIBundleToken.self).object(forInfoDictionaryKey: "CFBundleShortVersionString")
    as? String
  return .hello(protocol: LocalAIProtocol.version, version: version ?? "unknown")
}

/// Evaluates one small MLX op on the default device (the GPU on Apple silicon). A pass proves the
/// Metal library loads from this bundle's resources. Errors MLX reports are returned, not fatal.
private func gpuProbe() -> Event.Kind {
  do {
    let (device, value) = try withError { error in
      let sum = (MLXArray([1, 2, 3] as [Float]) * 2).sum()
      eval(sum)  // MLX.eval: runs the lazy array graph on the device
      try error.check()
      return (Device.defaultDevice().description, Double(sum.item(Float.self)))
    }
    return .gpu(.ok(device: device, value: value))
  } catch {
    return .gpu(.failed(error: error.localizedDescription))
  }
}

private func invalid(_ message: String, id: String?) -> Event {
  Event(id: id, kind: .error(code: .invalid, message: message))
}
