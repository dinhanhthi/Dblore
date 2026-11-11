// EngineEntry.swift
// Entry points shared by every database engine bundle. Dblore loads the bundle into its own
// process and calls the two C functions below (plain C types only): one engine protocol v1
// request JSON object in, event JSON objects out through a callback. The types and codec are the
// app's EnginePluginProtocol.swift, compiled into the bundle by path; requests are served by
// EngineRequestHandler.swift. Each engine target adds its driver: a global `engineDriver`
// conforming to `EngineDriver`.

import Foundation

/// Protocol version of the request and event objects
@_cdecl("dblore_engine_protocol")
public func dbloreEngineProtocol() -> Int32 { Int32(EnginePluginProtocol.version) }

/// Answers the request JSON object `json` (UTF-8, NUL-terminated) by calling `emit` with
/// `context` and one event JSON object (UTF-8, NUL-terminated) per call, echoing the request `id`.
/// `hello`, `close` of an unknown connection, unsupported kinds and unreadable requests are
/// answered before this returns; everything else later, from a connection queue, so `emit` and
/// `context` must stay valid for the life of the process. `more` and `cancel` get no answer of
/// their own (the cancelled request ends with `cancelled`). The string passed to `emit` is valid
/// only during that call. Never blocks on the network.
@_cdecl("dblore_engine_request")
public func dbloreEngineRequest(
  _ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
  _ emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
) {
  let callback = EmitCallback(context: context, emit: emit)
  EngineRequestHandler.shared.receive(
    Data(bytes: json, count: strlen(json)), sink: EventSink { callback.call($0) })
}

extension EngineRequestHandler {
  /// The handler of this bundle's `engineDriver`
  static let shared = EngineRequestHandler(driver: engineDriver)
}

/// The caller's callback and context, captured per request so a queue can answer later. The
/// caller keeps `context` alive and accepts calls from any thread (see `dbloreEngineRequest`).
private struct EmitCallback: @unchecked Sendable {
  let context: UnsafeMutableRawPointer?
  let emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

  func call(_ data: Data) {
    // Encoded JSON escapes every control character, so it holds no NUL
    String(decoding: data, as: UTF8.self).withCString { emit(context, $0) }
  }
}
