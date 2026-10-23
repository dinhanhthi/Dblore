// LocalAIEntry.swift
// On-device AI plugin entry points. Dblore loads this bundle into its own process and calls the two
// C functions below (plain C types only): one JSON request object in, JSON event objects out
// through a callback.

import Foundation
import MLX

/// Protocol version of the request and event objects.
@_cdecl("dblore_localai_protocol")
public func dbloreLocalAIProtocol() -> Int32 { 1 }

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
  var fallback = invalid("The event could not be encoded")
  fallback["id"] = event["id"]
  let data =
    encoded(event) ?? encoded(fallback)
    ?? Data(#"{"code":"invalid","event":"error","message":"The event could not be encoded"}"#.utf8)
  String(decoding: data, as: UTF8.self).withCString { emit(context, $0) }
}

/// The event as compact JSON with sorted keys, or nil when it is not a valid JSON object.
private func encoded(_ event: [String: Any]) -> Data? {
  guard JSONSerialization.isValidJSONObject(event) else { return nil }
  return try? JSONSerialization.data(
    withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Marks this bundle's image for `Bundle(for:)`.
private final class LocalAIBundleToken {}

/// Answers one request with exactly one event, echoing the request `id` when there is one
private func respond(to request: Data) -> [String: Any] {
  guard let request = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
  else { return invalid("The request is not a JSON object") }
  var event: [String: Any]
  switch request["type"] as? String {
  case "hello": event = hello()
  case "gpuProbe": event = gpuProbe()
  case let type?: event = invalid("Unknown request type \"\(type)\"")
  case nil: event = invalid("The request has no type")
  }
  if let id = request["id"] { event["id"] = id }
  return event
}

/// Protocol handshake only. It never touches MLX, so a GPU failure can't look like a load failure.
/// The version is this plugin bundle's, not the app's.
private func hello() -> [String: Any] {
  let version =
    Bundle(for: LocalAIBundleToken.self).object(forInfoDictionaryKey: "CFBundleShortVersionString")
    as? String
  return ["event": "hello", "protocol": 1, "version": version ?? "unknown"]
}

/// Evaluates one small MLX op on the default device (the GPU on Apple silicon). A pass proves the
/// Metal library loads from this bundle's resources. Errors MLX reports are returned, not fatal.
private func gpuProbe() -> [String: Any] {
  do {
    let (device, value) = try withError { error in
      let sum = (MLXArray([1, 2, 3] as [Float]) * 2).sum()
      eval(sum)  // MLX.eval: runs the lazy array graph on the device
      try error.check()
      return (Device.defaultDevice().description, Double(sum.item(Float.self)))
    }
    return ["event": "gpu", "ok": true, "device": device, "value": value]
  } catch {
    return ["event": "gpu", "ok": false, "error": error.localizedDescription]
  }
}

private func invalid(_ message: String) -> [String: Any] {
  ["event": "error", "code": "invalid", "message": message]
}
