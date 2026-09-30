// ChatGPTOAuthTests.swift
// Unit tests for the ChatGPT (Codex CLI) OAuth logic: PKCE, authorize URL, callback, tokens, JWT

import Foundation
import Testing

@testable import Dblore

@Suite("ChatGPT OAuth Tests")
struct ChatGPTOAuthTests {

  // MARK: - Helpers

  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func makeJWT(_ payload: [String: Any]) throws -> String {
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let body = base64URL(try JSONSerialization.data(withJSONObject: payload))
    return "\(header).\(body).sig"
  }

  private func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  // MARK: - PKCE

  @Test("challenge matches the RFC 7636 Appendix B vector")
  func rfc7636Vector() {
    #expect(
      PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test("generate yields a 43-char base64url verifier with a matching, unique challenge")
  func generateShape() {
    let a = PKCE.generate()
    let b = PKCE.generate()
    #expect(a.verifier.count == 43)
    #expect(
      a.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    )
    #expect(a.challenge == PKCE.challenge(for: a.verifier))
    #expect(a.verifier != b.verifier)
  }

  @Test("generateState is random base64url")
  func stateShape() {
    let a = ChatGPTOAuth.generateState()
    #expect(a.count == 43)
    #expect(a != ChatGPTOAuth.generateState())
  }

  // MARK: - Authorize URL

  @Test("authorize URL carries the expected query items")
  func authorizeURL() throws {
    let pkce = PKCE(verifier: "v", challenge: "chal")
    let url = ChatGPTOAuth.authorizeURL(pkce: pkce, state: "st", port: 1455)
    #expect(url.scheme == "https")
    #expect(url.host == "auth.openai.com")
    #expect(url.path == "/oauth/authorize")
    let q = queryItems(url)
    #expect(q["response_type"] == "code")
    #expect(q["client_id"] == ChatGPTOAuth.clientID)
    #expect(q["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
    #expect(q["scope"] == "openid profile email offline_access")
    #expect(q["code_challenge"] == "chal")
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["id_token_add_organizations"] == "true")
    #expect(q["codex_cli_simplified_flow"] == "true")
    #expect(q["state"] == "st")
  }

  // MARK: - Callback

  @Test("callback returns the code when state matches")
  func callbackOK() {
    let line = "GET /auth/callback?code=abc123&state=st HTTP/1.1"
    #expect(
      ChatGPTOAuth.parseCallback(requestLine: line, expectedState: "st") == .success("abc123"))
  }

  @Test("callback rejects a state mismatch even when a code is present")
  func callbackStateMismatch() {
    let line = "GET /auth/callback?code=abc123&state=evil HTTP/1.1"
    #expect(
      ChatGPTOAuth.parseCallback(requestLine: line, expectedState: "st")
        == .failure(.stateMismatch))
  }

  @Test("callback rejects a missing state")
  func callbackMissingState() {
    let line = "GET /auth/callback?code=abc123 HTTP/1.1"
    #expect(
      ChatGPTOAuth.parseCallback(requestLine: line, expectedState: "st")
        == .failure(.stateMismatch))
  }

  @Test("callback reports access_denied")
  func callbackDenied() {
    let line = "GET /auth/callback?error=access_denied&state=st HTTP/1.1"
    #expect(
      ChatGPTOAuth.parseCallback(requestLine: line, expectedState: "st")
        == .failure(.denied("access_denied")))
  }

  @Test(
    "callback only accepts GET /auth/callback",
    arguments: [
      "POST /auth/callback?code=a&state=st HTTP/1.1",
      "GET /other?code=a&state=st HTTP/1.1",
      "GET /auth/callback/x?code=a&state=st HTTP/1.1",
      "GET /auth/callback?state=st HTTP/1.1",
      "garbage",
      "",
    ])
  func callbackRejectsOthers(line: String) {
    if case .success = ChatGPTOAuth.parseCallback(requestLine: line, expectedState: "st") {
      Issue.record("accepted \(line)")
    }
  }

  // MARK: - Requests

  @Test("token request is a form-encoded authorization_code grant")
  func tokenRequest() throws {
    let req = ChatGPTOAuth.tokenRequest(code: "c d", verifier: "ver", port: 1457)
    #expect(req.url?.absoluteString == "https://auth.openai.com/oauth/token")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code=c%20d") || body.contains("code=c+d"))
    #expect(body.contains("code_verifier=ver"))
    #expect(body.contains("client_id=\(ChatGPTOAuth.clientID)"))
    #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1457%2Fauth%2Fcallback"))
  }

  @Test("refresh request is a JSON refresh_token grant")
  func refreshRequest() throws {
    let req = ChatGPTOAuth.refreshRequest(refreshToken: "rt")
    #expect(req.url?.absoluteString == "https://auth.openai.com/oauth/token")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
    #expect(json?["grant_type"] == "refresh_token")
    #expect(json?["refresh_token"] == "rt")
    #expect(json?["client_id"] == ChatGPTOAuth.clientID)
  }

  // MARK: - Token response and JWT

  @Test("token response parses tokens and JWT claims")
  func tokenResponse() throws {
    let idToken = try makeJWT([
      "exp": 2_000_000_000,
      "email": "me@example.com",
      "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"],
    ])
    let json: [String: Any] = [
      "access_token": "at", "refresh_token": "rt", "id_token": idToken, "expires_in": 3600,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let now = Date(timeIntervalSince1970: 1_000)
    let tokens = try ChatGPTOAuth.parseTokenResponse(data, now: now)
    #expect(tokens.accessToken == "at")
    #expect(tokens.refreshToken == "rt")
    #expect(tokens.idToken == idToken)
    #expect(tokens.expiresAt == now.addingTimeInterval(3600))
    #expect(tokens.accountID == "acct-1")
    #expect(tokens.email == "me@example.com")
  }

  @Test("refresh response without refresh/id token keeps the previous ones")
  func refreshKeepsPrevious() throws {
    let previous = ChatGPTTokens(
      accessToken: "old", refreshToken: "rt0", idToken: "id0",
      expiresAt: Date(timeIntervalSince1970: 0), accountID: "a", email: "e@x.com")
    let data = Data(#"{"access_token":"new","expires_in":60}"#.utf8)
    let tokens = try ChatGPTOAuth.parseTokenResponse(
      data, now: Date(timeIntervalSince1970: 10), previous: previous)
    #expect(tokens.accessToken == "new")
    #expect(tokens.refreshToken == "rt0")
    #expect(tokens.idToken == "id0")
    #expect(tokens.accountID == "a")
    #expect(tokens.email == "e@x.com")
  }

  @Test("malformed token responses throw without echoing the body")
  func tokenResponseInvalid() {
    for raw in ["not json", #"{"refresh_token":"SECRET"}"#, #"{"access_token":"SECRET"}"#] {
      do {
        _ = try ChatGPTOAuth.parseTokenResponse(Data(raw.utf8))
        Issue.record("accepted \(raw)")
      } catch {
        #expect(!String(describing: error).contains("SECRET"))
        #expect(!error.localizedDescription.contains("SECRET"))
      }
    }
  }

  @Test("JWT decode reads exp, email and account id; bad input gives nil")
  func jwtDecode() throws {
    let jwt = try makeJWT([
      "exp": 1_234, "email": "a@b.c",
      "https://api.openai.com/auth": ["chatgpt_account_id": "acct"],
    ])
    let claims = try #require(ChatGPTOAuth.decodeJWT(jwt))
    #expect(claims.exp == Date(timeIntervalSince1970: 1_234))
    #expect(claims.email == "a@b.c")
    #expect(claims.accountID == "acct")
    #expect(ChatGPTOAuth.decodeJWT("nodots") == nil)
    #expect(ChatGPTOAuth.decodeJWT("a.!!!.c") == nil)
  }

  // MARK: - needsRefresh

  @Test("needsRefresh flips 30 seconds before expiry")
  func needsRefreshBoundary() {
    let expiry = Date(timeIntervalSince1970: 10_000)
    let t = ChatGPTTokens(
      accessToken: "a", refreshToken: "r", idToken: "i", expiresAt: expiry, accountID: nil,
      email: nil)
    #expect(!t.needsRefresh(now: expiry.addingTimeInterval(-31)))
    #expect(t.needsRefresh(now: expiry.addingTimeInterval(-30)))
    #expect(t.needsRefresh(now: expiry.addingTimeInterval(1)))
  }

  // MARK: - Storage

  @Test("tokens round-trip through the key store as JSON under chatgpt.tokens")
  func storage() {
    let store = InMemoryAIKeyStore()
    let t = ChatGPTTokens(
      accessToken: "a", refreshToken: "r", idToken: "i",
      expiresAt: Date(timeIntervalSince1970: 5), accountID: "x", email: "e")
    #expect(ChatGPTTokenStorage.load(from: store) == nil)
    #expect(ChatGPTTokenStorage.save(t, to: store))
    #expect(store.load(account: "chatgpt.tokens") != nil)
    #expect(ChatGPTTokenStorage.load(from: store) == t)
    ChatGPTTokenStorage.delete(from: store)
    #expect(ChatGPTTokenStorage.load(from: store) == nil)
  }
}
