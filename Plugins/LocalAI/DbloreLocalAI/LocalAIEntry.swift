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
/// is one. Today every request gets exactly one event, emitted before this returns on the caller's
/// thread; callers must also accept calls later and from any thread. The string passed to `emit`
/// is valid only during that call.
@_cdecl("dblore_localai_request")
public func dbloreLocalAIRequest(
  _ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
  _ emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Void
) {
  let event = respond(to: Data(bytes: json, count: strlen(json)))
  // An event that can't be encoded (e.g. a non-finite number) still answers with an error event.
  let data =
    (try? LocalAIProtocol.encode(event))
    ?? (try? LocalAIProtocol.encode(invalid("The event could not be encoded", id: event.id)))
    ?? Data(#"{"code":"invalid","event":"error","message":"The event could not be encoded"}"#.utf8)
  String(decoding: data, as: UTF8.self).withCString { emit(context, $0) }
}

/// Marks this bundle's image for `Bundle(for:)`.
private final class LocalAIBundleToken {}

/// Answers one request with exactly one event, echoing the request `id`. Generation, cancel and
/// unload are not available yet.
private func respond(to data: Data) -> Event {
  guard let request = LocalAIProtocol.decodeRequest(data) else { return invalidRequest(data) }
  switch request.kind {
  case .hello: return Event(id: request.id, kind: hello())
  case .gpuProbe: return Event(id: request.id, kind: gpuProbe())
  case .generate, .cancel, .unload: return invalid("not available yet", id: request.id)
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
