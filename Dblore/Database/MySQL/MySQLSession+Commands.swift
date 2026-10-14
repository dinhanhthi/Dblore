// MySQLSession+Commands.swift
// The two statements MySQLSession sends. mysql-nio's own `simpleQuery` / `query` hand out
// column definitions only with a row, so a result with no rows has no header (spike 2.3).
// These commands report the header as soon as the server sent it:
// - `MySQLTextQuery`: COM_QUERY (text protocol), for statements without binds;
// - `MySQLPreparedQuery`: COM_STMT_PREPARE / EXECUTE / CLOSE (binary protocol), for binds.
// mysql-nio keeps the prepared packets' initializers internal, so they are written here.
// Both run on the connection's event loop; the callbacks must not block.

import Foundation
import MySQLNIO
import NIOCore

/// What a running statement reports, in order: `columns` once (empty for a statement without a
/// result set), `row` per row, then `ok` when the server sent an OK (affected rows, status).
nonisolated struct MySQLStatementCallbacks {
  var columns: ([MySQLProtocol.ColumnDefinition41]) -> Void
  var row: (MySQLRow) -> Void
  var ok: (MySQLProtocol.OK_Packet) -> Void
}

/// COM_QUERY: no binds, text protocol (exact values for every type).
nonisolated final class MySQLTextQuery: MySQLCommand, @unchecked Sendable {
  private enum State {
    case ready
    case columns(count: Int)
    case rows
  }

  private let sql: String
  private let callbacks: MySQLStatementCallbacks
  private var state = State.ready
  private var definitions: [MySQLProtocol.ColumnDefinition41] = []

  init(sql: String, callbacks: MySQLStatementCallbacks) {
    self.sql = sql
    self.callbacks = callbacks
  }

  func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
    MySQLCommandState(response: [
      try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)
    ])
  }

  func handle(
    packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags
  ) throws -> MySQLCommandState {
    if packet.isError {
      return MySQLCommandState(
        done: true, error: try MySQLStatementPackets.serverError(&packet, capabilities))
    }
    switch state {
    case .ready:
      if packet.isOK {
        callbacks.columns([])
        let ok = try MySQLProtocol.OK_Packet.decode(from: &packet, capabilities: capabilities)
        callbacks.ok(ok)
        return MySQLCommandState(done: true)
      }
      let response = try packet.decode(
        MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
      guard let count = Int(exactly: response.columnCount),
        MySQLStatementPackets.columnCountRange.contains(count)
      else { throw MySQLError.protocolError }
      state = .columns(count: count)
      return MySQLCommandState()
    case .columns(let count):
      definitions.append(
        try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
      if definitions.count == count {
        state = .rows
        callbacks.columns(definitions)
      }
      return MySQLCommandState()
    case .rows:
      // CLIENT_DEPRECATE_EOF: the result ends with an OK packet tagged 0xFE. A row whose first
      // value is 16 MiB or more also starts with 0xFE, in a packet of the maximum size.
      if packet.isEOF && packet.payload.readableBytes < 0xFF_FFFF {
        return MySQLCommandState(done: true)
      }
      let row = try MySQLProtocol.TextResultSetRow.decode(
        from: &packet, columnCount: definitions.count)
      callbacks.row(MySQLRow(format: .text, columnDefinitions: definitions, values: row.values))
      return MySQLCommandState()
    }
  }
}

/// COM_STMT_PREPARE, COM_STMT_EXECUTE with text / NULL binds, COM_STMT_CLOSE on every exit
/// (success or server error), the same state machine as mysql-nio's own prepared query.
nonisolated final class MySQLPreparedQuery: MySQLCommand, @unchecked Sendable {
  private enum State {
    case prepare
    case params(remaining: Int)
    case prepareColumns(remaining: Int)
    case executeColumnCount
    case executeColumns(remaining: Int)
    case rows
  }

  private let sql: String
  private let binds: [SQLBindValue]
  private let callbacks: MySQLStatementCallbacks
  private var state = State.prepare
  private var prepared: MySQLProtocol.COM_STMT_PREPARE_OK?
  private var definitions: [MySQLProtocol.ColumnDefinition41] = []

  init(sql: String, binds: [SQLBindValue], callbacks: MySQLStatementCallbacks) {
    self.sql = sql
    self.binds = binds
    self.callbacks = callbacks
  }

  func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
    var payload = ByteBufferAllocator().buffer(capacity: sql.utf8.count + 1)
    payload.writeInteger(UInt8(0x16))
    payload.writeString(sql)
    return MySQLCommandState(response: [MySQLPacket(payload: payload)])
  }

  func handle(
    packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags
  ) throws -> MySQLCommandState {
    if packet.isError {
      let error = try MySQLStatementPackets.serverError(&packet, capabilities)
      return MySQLCommandState(
        response: closePacket(), done: true, resetSequence: true, error: error)
    }
    switch state {
    case .prepare:
      let ok = try packet.decode(MySQLProtocol.COM_STMT_PREPARE_OK.self, capabilities: capabilities)
      prepared = ok
      if ok.numParams > 0 {
        state = .params(remaining: Int(ok.numParams))
      } else if ok.numColumns > 0 {
        state = .prepareColumns(remaining: Int(ok.numColumns))
      } else {
        state = .executeColumnCount
      }
      return MySQLCommandState(response: [executePacket(ok.statementID)], resetSequence: true)
    case .params(let remaining):
      _ = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
      if remaining > 1 {
        state = .params(remaining: remaining - 1)
      } else if let columns = prepared?.numColumns, columns > 0 {
        state = .prepareColumns(remaining: Int(columns))
      } else {
        state = .executeColumnCount
      }
      return MySQLCommandState()
    case .prepareColumns(let remaining):
      _ = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
      state = remaining > 1 ? .prepareColumns(remaining: remaining - 1) : .executeColumnCount
      return MySQLCommandState()
    case .executeColumnCount:
      if packet.isOK { return try finish(&packet, capabilities) }
      guard let count = MySQLStatementPackets.readLengthEncodedInteger(&packet.payload),
        let remaining = Int(exactly: count),
        MySQLStatementPackets.columnCountRange.contains(remaining)
      else { throw MySQLError.protocolError }
      state = .executeColumns(remaining: remaining)
      return MySQLCommandState()
    case .executeColumns(let remaining):
      definitions.append(
        try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
      if remaining > 1 {
        state = .executeColumns(remaining: remaining - 1)
      } else {
        state = .rows
        callbacks.columns(definitions)
      }
      return MySQLCommandState()
    case .rows:
      // A binary row also starts with 0x00, so OK only ends a result without columns.
      if packet.isEOF { return try finish(&packet, capabilities) }
      let values = try MySQLStatementPackets.binaryRow(&packet, columns: definitions)
      callbacks.row(MySQLRow(format: .binary, columnDefinitions: definitions, values: values))
      return MySQLCommandState()
    }
  }

  private func finish(
    _ packet: inout MySQLPacket, _ capabilities: MySQLProtocol.CapabilityFlags
  ) throws -> MySQLCommandState {
    if definitions.isEmpty {
      callbacks.columns([])
      let ok = try MySQLProtocol.OK_Packet.decode(from: &packet, capabilities: capabilities)
      callbacks.ok(ok)
    }
    return MySQLCommandState(response: closePacket(), done: true, resetSequence: true)
  }

  /// COM_STMT_EXECUTE: no cursor, one iteration, every bind sent as a string or NULL.
  private func executePacket(_ statementID: UInt32) -> MySQLPacket {
    var payload = ByteBufferAllocator().buffer(capacity: 16)
    payload.writeInteger(UInt8(0x17))
    payload.writeInteger(statementID, endianness: .little)
    payload.writeInteger(UInt8(0))
    payload.writeInteger(UInt32(1), endianness: .little)
    guard !binds.isEmpty else { return MySQLPacket(payload: payload) }
    var nullBitmap = [UInt8](repeating: 0, count: (binds.count + 7) / 8)
    for (index, bind) in binds.enumerated() where bind == .null {
      nullBitmap[index / 8] |= 1 << UInt8(index % 8)
    }
    payload.writeBytes(nullBitmap)
    payload.writeInteger(UInt8(1))
    for bind in binds {
      let type: MySQLProtocol.DataType = bind == .null ? .null : .varString
      payload.writeInteger(type.rawValue)
      payload.writeInteger(UInt8(0))
    }
    for case .text(let text) in binds {
      MySQLStatementPackets.writeLengthEncodedInteger(UInt64(text.utf8.count), to: &payload)
      payload.writeString(text)
    }
    return MySQLPacket(payload: payload)
  }

  /// COM_STMT_CLOSE (no reply), or nothing when PREPARE itself failed.
  private func closePacket() -> [MySQLPacket] {
    guard let statementID = prepared?.statementID else { return [] }
    prepared = nil
    var payload = ByteBufferAllocator().buffer(capacity: 5)
    payload.writeInteger(UInt8(0x19))
    payload.writeInteger(statementID, endianness: .little)
    return [MySQLPacket(payload: payload)]
  }
}

/// Packet pieces both commands share.
nonisolated enum MySQLStatementPackets {
  /// A result set has 1 to 4096 columns (MySQL's limit); anything else from the server is a
  /// protocol error, so a hostile count cannot grow the column definitions without bound.
  static let columnCountRange = 1...4096

  /// The ERR packet as `MySQLError.server`.
  static func serverError(
    _ packet: inout MySQLPacket, _ capabilities: MySQLProtocol.CapabilityFlags
  ) throws -> MySQLError {
    .server(try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities))
  }

  /// One binary-protocol row: header 0x00, NULL bitmap (offset 2), then each value, fixed
  /// width for numbers and length-encoded otherwise (dates and times carry a length byte).
  static func binaryRow(
    _ packet: inout MySQLPacket, columns: [MySQLProtocol.ColumnDefinition41]
  ) throws -> [ByteBuffer?] {
    guard packet.payload.readInteger(as: UInt8.self) == 0x00,
      let nulls = MySQLProtocol.NullBitmap.readResultSetNullBitmap(
        count: columns.count, from: &packet.payload)
    else { throw MySQLError.protocolError }
    var values: [ByteBuffer?] = []
    values.reserveCapacity(columns.count)
    for (index, column) in columns.enumerated() {
      if nulls.isNull(at: index) {
        values.append(nil)
        continue
      }
      let slice: ByteBuffer?
      if let width = fixedWidth(column.columnType) {
        slice = packet.payload.readSlice(length: width)
      } else if let length = readLengthEncodedInteger(&packet.payload).flatMap(Int.init(exactly:)) {
        slice = packet.payload.readSlice(length: length)
      } else {
        slice = nil
      }
      guard var slice else { throw MySQLError.protocolError }
      var copy = ByteBufferAllocator().buffer(capacity: slice.readableBytes)
      copy.writeBuffer(&slice)
      values.append(copy)
    }
    return values
  }

  /// Bytes of a fixed-width binary value; nil for a length-encoded one.
  private static func fixedWidth(_ type: MySQLProtocol.DataType) -> Int? {
    switch type {
    case .tiny: 1
    case .short, .year: 2
    case .long, .int24, .float: 4
    case .longlong, .double: 8
    default: nil
    }
  }

  static func readLengthEncodedInteger(_ buffer: inout ByteBuffer) -> UInt64? {
    guard let first = buffer.readInteger(as: UInt8.self) else { return nil }
    switch first {
    case 0xFC: return buffer.readInteger(endianness: .little, as: UInt16.self).map(UInt64.init)
    case 0xFD:
      return buffer.readBytes(length: 3).map {
        UInt64($0[0]) | UInt64($0[1]) << 8 | UInt64($0[2]) << 16
      }
    case 0xFE: return buffer.readInteger(endianness: .little, as: UInt64.self)
    case 0xFB, 0xFF: return nil
    default: return UInt64(first)
    }
  }

  static func writeLengthEncodedInteger(_ value: UInt64, to buffer: inout ByteBuffer) {
    switch value {
    case ..<0xFB:
      buffer.writeInteger(UInt8(value))
    case ...0xFFFF:
      buffer.writeInteger(UInt8(0xFC))
      buffer.writeInteger(UInt16(value), endianness: .little)
    case ...0xFF_FFFF:
      buffer.writeInteger(UInt8(0xFD))
      buffer.writeBytes([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16)])
    default:
      buffer.writeInteger(UInt8(0xFE))
      buffer.writeInteger(value, endianness: .little)
    }
  }
}
