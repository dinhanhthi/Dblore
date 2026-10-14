// MongoSRVResolver.swift
// `mongodb+srv://` seed lists (2.6 Q5 fallback): the app resolves the SRV and TXT records itself
// with dnssd (`DNSServiceQueryRecord`) and hands MongoKitten plain hosts, so MongoKitten's
// DNSClient path (which reads no TXT) is never used. Rules from the Initial DNS Seedlist
// Discovery spec:
// - the SRV name is `_mongodb._tcp.<host>`; the host needs at least three dot-separated parts;
// - every target must end with the host's parent domain (`<host without its first label>`);
// - at most one TXT record; its strings are joined and read as URI options, of which only
//   `authSource`, `replicaSet` and `loadBalanced` are allowed (`loadBalanced=true` is refused);
//   options in the connection string win over TXT options (applied by `MongoSession`).
// DNS answers are external input: errors never echo record text.

import Foundation
import dnssd

/// One SRV answer.
nonisolated struct MongoSRVRecord: Equatable, Sendable {
  var priority: UInt16
  var weight: UInt16
  var port: Int
  /// Target host name, without the trailing dot.
  var target: String
}

/// DNS lookups for `mongodb+srv://`. Tests inject a fake.
nonisolated protocol MongoSRVResolving: Sendable {
  /// SRV answers for `name`. Throws when the name has no SRV record.
  func srvRecords(_ name: String) async throws -> [MongoSRVRecord]
  /// TXT answers for `name`, each record's strings joined. Empty when the name has none.
  func txtRecords(_ name: String) async throws -> [String]
}

/// The hosts and options a `mongodb+srv://` host resolves to.
nonisolated struct MongoSeedlist: Equatable, Sendable {
  var hosts: [ParsedMongoURI.Host]
  var authSource: String?
  var replicaSet: String?
}

nonisolated enum MongoSRV {
  nonisolated struct LookupError: Error, Equatable, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Seed list of `host` (the `+srv` host of the connection string).
  static func seedlist(
    for host: String, resolver: any MongoSRVResolving
  ) async throws -> MongoSeedlist {
    let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 3, !labels.contains(where: \.isEmpty) else {
      throw LookupError(
        message:
          "A mongodb+srv:// host needs at least three parts (for example cluster0.example.com).")
    }
    let domain = "." + labels.dropFirst().joined(separator: ".")
    let records = try await resolver.srvRecords("_mongodb._tcp." + host)
    guard !records.isEmpty else {
      throw LookupError(message: "No SRV record was found for the mongodb+srv:// host.")
    }
    let hosts = try records.map { record -> ParsedMongoURI.Host in
      let target = record.target.lowercased()
      guard target.hasSuffix(domain), target.count > domain.count else {
        throw LookupError(
          message: "An SRV record points outside the domain of the mongodb+srv:// host.")
      }
      return ParsedMongoURI.Host(name: target, port: record.port)
    }
    let texts = try await resolver.txtRecords(host)
    guard texts.count <= 1 else {
      throw LookupError(message: "The mongodb+srv:// host has more than one TXT record.")
    }
    var seedlist = MongoSeedlist(hosts: hosts, authSource: nil, replicaSet: nil)
    if let text = texts.first { try applyTXTOptions(text, to: &seedlist) }
    return seedlist
  }

  /// `authSource=…&replicaSet=…` from the TXT record. Any other option is refused.
  static func applyTXTOptions(_ text: String, to seedlist: inout MongoSeedlist) throws {
    for pair in text.split(separator: "&") where !pair.isEmpty {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, let key = String(parts[0]).removingPercentEncoding,
        let value = String(parts[1]).removingPercentEncoding, !value.isEmpty
      else { throw LookupError(message: "The TXT record of the mongodb+srv:// host is not valid.") }
      switch key.lowercased() {
      case "authsource": seedlist.authSource = value
      case "replicaset": seedlist.replicaSet = value
      case "loadbalanced" where value.lowercased() == "false": break
      case "loadbalanced":
        throw LookupError(message: "Load-balanced MongoDB clusters are not supported.")
      default:
        throw LookupError(
          message:
            "The TXT record of the mongodb+srv:// host sets an option other than authSource, "
            + "replicaSet or loadBalanced.")
      }
    }
  }

  /// SRV RDATA: priority, weight, port (big endian), then the uncompressed target name.
  static func parseSRV(_ rdata: [UInt8]) -> MongoSRVRecord? {
    guard rdata.count >= 7 else { return nil }
    func word(_ index: Int) -> UInt16 { UInt16(rdata[index]) << 8 | UInt16(rdata[index + 1]) }
    var labels: [String] = []
    var index = 6
    while index < rdata.count {
      let length = Int(rdata[index])
      index += 1
      if length == 0 { break }
      // A compression pointer (0xC0) cannot appear in dnssd answers; refuse it.
      guard length < 64, index + length <= rdata.count else { return nil }
      guard let label = String(bytes: rdata[index..<index + length], encoding: .utf8) else {
        return nil
      }
      labels.append(label)
      index += length
    }
    guard !labels.isEmpty else { return nil }
    return MongoSRVRecord(
      priority: word(0), weight: word(2), port: Int(word(4)),
      target: labels.joined(separator: "."))
  }

  /// TXT RDATA: length-prefixed strings, joined.
  static func parseTXT(_ rdata: [UInt8]) -> String? {
    var text = ""
    var index = 0
    while index < rdata.count {
      let length = Int(rdata[index])
      index += 1
      guard index + length <= rdata.count,
        let part = String(bytes: rdata[index..<index + length], encoding: .utf8)
      else { return nil }
      text += part
      index += length
    }
    return text
  }
}

/// `DNSServiceQueryRecord` on a private dispatch queue, bounded by `timeoutSeconds`.
nonisolated struct MongoDNSServiceResolver: MongoSRVResolving {
  var timeoutSeconds: Int

  func srvRecords(_ name: String) async throws -> [MongoSRVRecord] {
    try await DNSRecordLookup.run(
      name: name, type: UInt16(kDNSServiceType_SRV), timeout: timeoutSeconds
    )
    .compactMap(MongoSRV.parseSRV)
  }

  func txtRecords(_ name: String) async throws -> [String] {
    try await DNSRecordLookup.run(
      name: name, type: UInt16(kDNSServiceType_TXT), timeout: timeoutSeconds, emptyIfMissing: true
    ).compactMap(MongoSRV.parseTXT)
  }
}

/// One dnssd query. Every callback and the deadline run on `queue`, so `finish` needs no lock.
private nonisolated final class DNSRecordLookup: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dblore.mongo.dns")
  private let type: UInt16
  private let emptyIfMissing: Bool
  private var reference: DNSServiceRef?
  /// `self` is retained for dnssd's raw context pointer until `finish`.
  private var isRetained = false
  private var records: [[UInt8]] = []
  private var continuation: CheckedContinuation<[[UInt8]], Error>?

  private init(
    type: UInt16, emptyIfMissing: Bool, continuation: CheckedContinuation<[[UInt8]], Error>
  ) {
    self.type = type
    self.emptyIfMissing = emptyIfMissing
    self.continuation = continuation
  }

  static func run(
    name: String, type: UInt16, timeout: Int, emptyIfMissing: Bool = false
  ) async throws -> [[UInt8]] {
    try await withCheckedThrowingContinuation { continuation in
      let lookup = DNSRecordLookup(
        type: type, emptyIfMissing: emptyIfMissing, continuation: continuation)
      lookup.queue.async { lookup.start(name: name, timeout: timeout) }
    }
  }

  private func start(name: String, timeout: Int) {
    // Balanced by the release in `finish`; dnssd holds only this raw pointer.
    let context = Unmanaged.passRetained(self).toOpaque()
    isRetained = true
    var reference: DNSServiceRef?
    let status = DNSServiceQueryRecord(
      &reference, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name, type,
      UInt16(kDNSServiceClass_IN), dnsRecordReply, context)
    guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let reference else {
      finish(.failure(MongoSRV.LookupError(message: "The DNS lookup could not start.")))
      return
    }
    self.reference = reference
    DNSServiceSetDispatchQueue(reference, queue)
    queue.asyncAfter(deadline: .now() + .seconds(max(1, timeout))) { [self] in
      finish(.failure(MongoSRV.LookupError(message: "The DNS lookup timed out.")))
    }
  }

  fileprivate func handle(
    flags: DNSServiceFlags, error: DNSServiceErrorType, type: UInt16, rdata: [UInt8]
  ) {
    if error == DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) {
      if records.isEmpty && !emptyIfMissing {
        finish(.failure(MongoSRV.LookupError(message: "No DNS record was found.")))
      } else {
        finish(.success(records))
      }
      return
    }
    guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
      finish(.failure(MongoSRV.LookupError(message: "The DNS lookup failed (\(error)).")))
      return
    }
    // Intermediate answers (a CNAME) carry another type.
    if type == self.type, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
      records.append(rdata)
    }
    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0, !records.isEmpty {
      finish(.success(records))
    }
  }

  private func finish(_ result: Result<[[UInt8]], Error>) {
    guard let continuation else { return }
    self.continuation = nil
    if let reference {
      DNSServiceRefDeallocate(reference)
      self.reference = nil
    }
    if isRetained {
      isRetained = false
      Unmanaged.passUnretained(self).release()
    }
    continuation.resume(with: result)
  }
}

private nonisolated let dnsRecordReply: DNSServiceQueryRecordReply = {
  _, flags, _, error, _, type, _, length, data, _, context in
  guard let context else { return }
  let lookup = Unmanaged<DNSRecordLookup>.fromOpaque(context).takeUnretainedValue()
  let rdata = data.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(length))) } ?? []
  lookup.handle(flags: flags, error: error, type: type, rdata: rdata)
}
