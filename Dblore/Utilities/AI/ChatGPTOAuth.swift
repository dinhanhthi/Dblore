// ChatGPTOAuth.swift
// Pure logic for "Sign in with ChatGPT" (Codex CLI OAuth, unofficial): PKCE, URLs, tokens, JWT

import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636) verifier and S256 challenge
nonisolated struct PKCE: Sendable, Equatable {
  let verifier: String
  let challenge: String

  /// 32 cryptographically random bytes, base64url without padding
  static func generate() -> PKCE {
    let verifier = ChatGPTOAuth.randomBase64URL(byteCount: 32)
    return PKCE(verifier: verifier, challenge: challenge(for: verifier))
  }

  static func challenge(for verifier: String) -> String {
    ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }
}

nonisolated enum ChatGPTOAuthError: LocalizedError, Sendable, Equatable {
  case stateMismatch
  case denied(String)
  case invalidCallback
  case invalidTokenResponse
  case portInUse

  var errorDescription: String? {
    switch self {
    case .stateMismatch:
      return "The sign-in response did not match this sign-in attempt. Try again."
    case .denied(let reason):
      return "Sign-in was not completed (\(reason))."
    case .invalidCallback:
      return "The sign-in response was not valid."
    case .invalidTokenResponse:
      return "ChatGPT returned an unexpected sign-in response."
    case .portInUse:
      return "Ports 1455 and 1457 are in use. Quit the Codex CLI and try again."
    }
  }
}

nonisolated struct ChatGPTTokens: Codable, Equatable, Sendable {
  var accessToken: String
  var refreshToken: String
  var idToken: String
  var expiresAt: Date
  var accountID: String?
  var email: String?

  /// True from 30 seconds before expiry
  func needsRefresh(now: Date) -> Bool {
    now >= expiresAt.addingTimeInterval(-ChatGPTOAuth.refreshLeeway)
  }
}

/// Claims read from the id token payload. The signature is NOT verified: display and account id only.
nonisolated struct ChatGPTJWTClaims: Equatable, Sendable {
  let exp: Date?
  let email: String?
  let accountID: String?
}

nonisolated enum ChatGPTOAuth: Sendable {
  static let issuer = "https://auth.openai.com"
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let scopes = "openid profile email offline_access"
  static let refreshLeeway: TimeInterval = 30
  static let callbackPath = "/auth/callback"

  // MARK: - Randomness and encoding

  static func randomBase64URL(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return base64URL(Data(bytes))
  }

  static func generateState() -> String {
    randomBase64URL(byteCount: 32)
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func data(fromBase64URL string: String) -> Data? {
    var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    return Data(base64Encoded: s)
  }

  // MARK: - URLs and requests

  static func redirectURI(port: Int) -> String {
    "http://127.0.0.1:\(port)\(callbackPath)"
  }

  static func authorizeURL(pkce: PKCE, state: String, port: Int) -> URL {
    var components = URLComponents(string: issuer + "/oauth/authorize")!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
      URLQueryItem(name: "scope", value: scopes),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "state", value: state),
    ]
    return components.url!
  }

  private static var tokenURL: URL { URL(string: issuer + "/oauth/token")! }

  static func tokenRequest(code: String, verifier: String, port: Int) -> URLRequest {
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formEncode([
      ("grant_type", "authorization_code"),
      ("code", code),
      ("redirect_uri", redirectURI(port: port)),
      ("client_id", clientID),
      ("code_verifier", verifier),
    ])
    return request
  }

  /// The Codex CLI refreshes with a JSON body
  static func refreshRequest(refreshToken: String) -> URLRequest {
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = [
      "client_id": clientID,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func formEncode(_ pairs: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = pairs.map { name, value in
      "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }
    return Data(encoded.joined(separator: "&").utf8)
  }

  // MARK: - Callback

  /// Parses the first line of the loopback request. Accepts only `GET /auth/callback`, and checks
  /// `state` before returning the code or the provider error.
  static func parseCallback(
    requestLine: String, expectedState: String
  ) -> Result<
    String, ChatGPTOAuthError
  > {
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, parts[0] == "GET",
      let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
      components.path == callbackPath
    else { return .failure(.invalidCallback) }

    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    guard let state = value("state"), constantTimeEquals(state, expectedState) else {
      return .failure(.stateMismatch)
    }
    if let error = value("error") {
      return .failure(.denied(String(error.prefix(64))))
    }
    guard let code = value("code"), !code.isEmpty else { return .failure(.invalidCallback) }
    return .success(code)
  }

  private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
  }

  // MARK: - Tokens

  private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double?
  }

  /// Parses a token or refresh response. A refresh response may omit `refresh_token` / `id_token`;
  /// then `previous` supplies them. Errors never include response content.
  static func parseTokenResponse(
    _ data: Data, now: Date = Date(), previous: ChatGPTTokens? = nil
  ) throws(ChatGPTOAuthError) -> ChatGPTTokens {
    guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
      let refreshToken = response.refresh_token ?? previous?.refreshToken,
      let idToken = response.id_token ?? previous?.idToken
    else { throw .invalidTokenResponse }

    let claims = decodeJWT(idToken)
    let expiresAt =
      response.expires_in.map { now.addingTimeInterval($0) }
      ?? decodeJWT(response.access_token)?.exp ?? claims?.exp
    guard let expiresAt else { throw .invalidTokenResponse }

    return ChatGPTTokens(
      accessToken: response.access_token,
      refreshToken: refreshToken,
      idToken: idToken,
      expiresAt: expiresAt,
      accountID: claims?.accountID ?? previous?.accountID,
      email: claims?.email ?? previous?.email)
  }

  /// Decodes the JWT payload without verifying the signature (display / account id only)
  static func decodeJWT(_ jwt: String) -> ChatGPTJWTClaims? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let data = data(fromBase64URL: String(parts[1])),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let auth = payload["https://api.openai.com/auth"] as? [String: Any]
    return ChatGPTJWTClaims(
      exp: (payload["exp"] as? Double).map { Date(timeIntervalSince1970: $0) },
      email: payload["email"] as? String,
      accountID: auth?["chatgpt_account_id"] as? String)
  }
}

/// Persists `ChatGPTTokens` as JSON in the AI key store
nonisolated enum ChatGPTTokenStorage: Sendable {
  static let account = "chatgpt.tokens"

  static func load(from store: AIKeyStore) -> ChatGPTTokens? {
    guard let json = store.load(account: account) else { return nil }
    return try? JSONDecoder().decode(ChatGPTTokens.self, from: Data(json.utf8))
  }

  @discardableResult
  static func save(_ tokens: ChatGPTTokens, to store: AIKeyStore) -> Bool {
    guard let data = try? JSONEncoder().encode(tokens) else { return false }
    return store.save(String(decoding: data, as: UTF8.self), account: account)
  }

  static func delete(from store: AIKeyStore) {
    store.delete(account: account)
  }
}
