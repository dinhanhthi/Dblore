//
//  ConnectionFormContent+AI.swift
//  Dblore
//
//  AI section of the connection form: the connection's AI access policy and its rules
//

import SwiftUI

// MARK: - AI Draft

/// The AI policy and rules the connection form edits. The form binds them straight to the
/// config; this type holds the options, labels, seed and edited check.
nonisolated struct ConnectionAIDraft: Equatable, Sendable {
  var access: AIAccessPolicy = .useDefault
  var rules = ""
  /// Remember was on: a save writes the saved row (see `isEdited(from:)`)
  var remembered = true

  init() {}

  init(config: ConnectionConfig) {
    access = config.aiAccess
    rules = config.aiRules
    remembered = config.rememberConnection
  }

  /// Picker order
  static let policyOptions: [AIAccessPolicy] = [.useDefault, .always, .askOncePerSession, .never]

  /// "Use default" names what it follows (`defaultPolicy`). A global Use default has nothing to
  /// follow and asks (`AIAccessGate`).
  static func policyTitle(_ policy: AIAccessPolicy, default defaultPolicy: AIAccessPolicy) -> String
  {
    guard policy == .useDefault else { return policy.title }
    let followed = defaultPolicy == .useDefault ? .askOncePerSession : defaultPolicy
    return "\(policy.title) (\(followed.title))"
  }

  static func policySummary(_ policy: AIAccessPolicy) -> String {
    switch policy {
    case .useDefault: "Follows the default in Settings > AI."
    case .always: "AI features may read this connection's schema, queries and results."
    case .askOncePerSession: "Asks the first time AI features use this connection in a session."
    case .never: "Nothing from this connection reaches an AI model."
    }
  }

  /// "n / 2,000"
  static func counterText(_ rules: String) -> String {
    let locale = Locale(identifier: "en_US")
    let count = rules.count.formatted(.number.locale(locale))
    return "\(count) / \(ConnectionConfig.aiRulesLimit.formatted(.number.locale(locale)))"
  }

  /// What the form starts from: the AI fields `saved` carries, those of the exact row a save of
  /// `config` writes (Remember on), so a stale copy never overwrites a stricter saved policy. With
  /// Remember off nothing is written and the live values stay.
  static func seed(for config: ConnectionConfig, saved: ConnectionConfig?) -> ConnectionAIDraft {
    var seed = ConnectionAIDraft(config: config)
    if config.rememberConnection, let saved {
      seed.access = saved.aiAccess
      seed.rules = saved.aiRules
    }
    return seed
  }

  /// `config` with this policy and these rules (clamped to `ConnectionConfig.aiRulesLimit`)
  func applied(to config: ConnectionConfig) -> ConnectionConfig {
    var config = config
    config.aiAccess = access
    config.aiRules = rules
    return config
  }

  /// The user changed the policy or the rules since `seed`, or turned Remember on after a seed
  /// taken with it off: that seed holds the live values, not the saved row's, so a save writes
  /// the shown values instead of keeping the saved row's (which the form never showed).
  func isEdited(from seed: ConnectionAIDraft) -> Bool {
    access != seed.access || rules != seed.rules || (remembered && !seed.remembered)
  }
}

// MARK: - AI Section

extension ConnectionFormContent {
  /// The policy picker and the rules editor. The section card supplies the "AI" title.
  @ViewBuilder
  func aiSection() -> some View {
    let defaultPolicy = AISettings.shared.configuration.defaultConnectionAccess
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text("AI access")
            .font(.body)
          Text(ConnectionAIDraft.policySummary(connectionConfig.aiAccess))
            .font(.caption)
            .foregroundColor(.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        Menu {
          ForEach(ConnectionAIDraft.policyOptions, id: \.self) { policy in
            Button(ConnectionAIDraft.policyTitle(policy, default: defaultPolicy)) {
              connectionConfig.aiAccess = policy
            }
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Text(ConnectionAIDraft.policyTitle(connectionConfig.aiAccess, default: defaultPolicy))
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption)
              .foregroundColor(.foregroundMuted)
          }
          .dropdownCapsuleStyle()
        }
        .buttonStyle(.plain)
        .linkPointer()
        .fixedSize()
      }

      FormField(label: "Rules sent to the model with this connection") {
        TextEditor(text: $connectionConfig.aiRules)
          .scrollContentBackground(.hidden)
          .frame(height: 72)
          .textAreaCapsuleStyle()
      }
      Text(ConnectionAIDraft.counterText(connectionConfig.aiRules))
        .font(.caption)
        .monospacedDigit()
        .foregroundColor(.foregroundMuted)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  /// The AI fields the form starts from (see `ConnectionAIDraft.seed`): the exact saved row's,
  /// the one a save writes (`keepingSavedAIFields`). Run when the form opens and whenever it
  /// loads another connection, never after a plain field edit.
  func seedAIFields() {
    let seed = ConnectionAIDraft.seed(
      for: connectionConfig, saved: WorkspaceManager.keepingSavedAIFields(connectionConfig))
    aiSeed = seed
    if ConnectionAIDraft(config: connectionConfig) != seed {
      connectionConfig = seed.applied(to: connectionConfig)
    }
  }

  /// True when the user changed the AI fields since the form was seeded, or turned Remember on
  /// after a seed taken with it off (see `ConnectionAIDraft.isEdited(from:)`)
  var aiFieldsEdited: Bool {
    ConnectionAIDraft(config: connectionConfig).isEdited(from: aiSeed)
  }
}
