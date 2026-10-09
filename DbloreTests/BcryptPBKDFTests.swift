// BcryptPBKDFTests.swift
// Known-answer tests for the OpenBSD bcrypt_pbkdf port. Vectors are the published set from
// pyca/bcrypt tests/test_bcrypt.py (test_kdf), which mirrors OpenBSD's bcrypt_pbkdf output.

import Foundation
import Testing

@testable import Dblore

struct BcryptPBKDFTests {
  struct Vector: Sendable, CustomTestStringConvertible {
    let rounds: Int
    let password: String
    let salt: String
    let expected: String

    var testDescription: String { "rounds \(rounds), \(expected.count / 2) bytes" }
  }

  static let vectors: [Vector] = [
    Vector(
      rounds: 4, password: "70617373776f7264", salt: "73616c74",
      expected: "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"),
    Vector(
      rounds: 4, password: "70617373776f7264", salt: "00",
      expected: "c12b566235eee04c212598970a579a67"),
    Vector(
      rounds: 4, password: "00", salt: "73616c74",
      expected: "6051be18c2f4f82cbf0efee5471b4bb9"),
    Vector(
      rounds: 4, password: "70617373776f726400", salt: "73616c7400",
      expected: "7410e44cf4fa07bfaac8a928b1727fac001375e7bf7384370f48efd121743050"),
    Vector(
      rounds: 4, password: "7061737300776f72", salt: "7361006c",
      expected: "c2bffd9db38f6569efef4372f4de83c0"),
    Vector(
      rounds: 4, password: "7061737300776f7264", salt: "7361006c74",
      expected: "4ba4ac3925c0e8d7f0cdb6bb1684a56f"),
    Vector(
      rounds: 8, password: "70617373776f7264", salt: "73616c74",
      expected:
        "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec76227ea66088b849b20ab7aa478010246e74bba51723fefa9f9474d6508845e8d"
    ),
    Vector(
      rounds: 42, password: "70617373776f7264", salt: "73616c74",
      expected: "833cf0dcf56db65608e8f0dc0ce882bd"),
    Vector(
      rounds: 8,
      password:
        "4c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e20557420656e696d206164206d696e696d2076656e69616d2c2071756973206e6f737472756420657865726369746174696f6e20756c6c616d636f206c61626f726973206e69736920757420616c697175697020657820656120636f6d6d6f646f20636f6e7365717561742e2044756973206175746520697275726520646f6c6f7220696e20726570726568656e646572697420696e20766f6c7570746174652076656c697420657373652063696c6c756d20646f6c6f726520657520667567696174206e756c6c612070617269617475722e204578636570746575722073696e74206f6363616563617420637570696461746174206e6f6e2070726f6964656e742c2073756e7420696e2063756c706120717569206f666669636961206465736572756e74206d6f6c6c697420616e696d20696420657374206c61626f72756d2e",
      salt: "73616c697300",
      expected: "10978b07253df57f71a162eb0e8ad30a"),
    Vector(
      rounds: 8, password: "0db3ac94b3ee53284f4a22893b3c24ae",
      salt: "3a62f0f0dbcef823cfcc854856ea1028",
      expected: "204438175eee7ce136c91b49a67923ff"),
    Vector(
      rounds: 8, password: "0db3ac94b3ee53284f4a22893b3c24ae",
      salt: "3a62f0f0dbcef823cfcc854856ea1028",
      expected:
        "2054b9fff34e3721440334746828e9ed38de4b72e0a69adc170a13b5e8d646385ea4034ae6d26600ee2332c5ed40ad557c86e3403fbb30e4e1dc1ae06b99a071368f518d2c426651c9e7e437fd6c915b1bbfc3a4cea71491490ea7afb7dd0290a678a4f441128db1792eab2776b21eb4238e0715add4127dff44e4b3e4cc4c4f9970083f3f74bd698873fdf648844f75c9bf7f9e0c4d9e5d89a7783997492966616707611cb901de31a19726b6e08c3a8001661f2d5c9dcc33b4aa072f90dd0b3f548d5eeba4211397e2fb062e526e1d68f46a4ce256185b4badc2685fbe78e1c7657b59f83ab9ab80cf9318d6add1f5933f12d6f36182c8e8115f68030a1244"
    ),
    Vector(
      rounds: 8, password: "e1bd88ceb4cf85cf83cf83ceb5cf8dcf82",
      salt: "cea4ceb7cebbceadcebcceb1cf87cebfcf82",
      expected: "43666c9b09ef33ed8c27e8e8f3e2d8e6"),
  ]

  @Test(arguments: vectors)
  func matchesPublishedVector(_ vector: Vector) throws {
    let derived = try BcryptPBKDF.derive(
      password: bytes(vector.password), salt: bytes(vector.salt), rounds: vector.rounds,
      keyLength: vector.expected.count / 2)
    #expect(hex(derived) == vector.expected)
  }

  @Test func rejectsOutOfRangeInputs() {
    let password = Array("password".utf8)
    let salt = Array("salt".utf8)
    #expect(throws: BcryptPBKDF.Error.invalidRounds) {
      try BcryptPBKDF.derive(password: password, salt: salt, rounds: 0, keyLength: 32)
    }
    #expect(throws: BcryptPBKDF.Error.invalidKeyLength) {
      try BcryptPBKDF.derive(password: password, salt: salt, rounds: 4, keyLength: 0)
    }
    #expect(throws: BcryptPBKDF.Error.invalidKeyLength) {
      try BcryptPBKDF.derive(password: password, salt: salt, rounds: 4, keyLength: 1025)
    }
    #expect(throws: BcryptPBKDF.Error.invalidSalt) {
      try BcryptPBKDF.derive(password: password, salt: [], rounds: 4, keyLength: 32)
    }
    #expect(throws: BcryptPBKDF.Error.emptyPassword) {
      try BcryptPBKDF.derive(password: [], salt: salt, rounds: 4, keyLength: 32)
    }
  }

  private func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      result.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return result
  }

  private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
