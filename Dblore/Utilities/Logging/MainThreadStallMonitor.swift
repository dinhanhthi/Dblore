//
//  MainThreadStallMonitor.swift
//  Dblore
//
//  Logs main run-loop turns of 50 ms or more (unified log category "stall")
//

import Foundation
import OSLog

/// A run-loop observer on the main thread: a turn runs from waking up to going back to sleep.
/// Each turn of `threshold` or more is logged with its duration and emitted as a PerfSignpost
/// event. On in Debug builds; in Release only with the launch argument `-DbloreStallMonitor YES`.
/// Nothing is installed when off.
final class MainThreadStallMonitor {
  private static var installed: MainThreadStallMonitor?
  private static let logger = Logger(subsystem: "ace.thi.dblore.app", category: "stall")

  private let threshold: UInt64 = 50_000_000
  private var observer: CFRunLoopObserver?
  /// Uptime when the current turn woke up; nil while asleep or before the first wake
  private var turnStart: UInt64?

  static var isEnabled: Bool {
    #if DEBUG
      true
    #else
      UserDefaults.standard.bool(forKey: "DbloreStallMonitor")
    #endif
  }

  static func installIfEnabled() {
    guard installed == nil, isEnabled else { return }
    let monitor = MainThreadStallMonitor()
    monitor.install()
    installed = monitor
  }

  private func install() {
    let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, activities.rawValue, true, 0
    ) { [weak self] _, activity in
      // The main run loop calls back on the main thread
      MainActor.assumeIsolated { self?.handle(activity) }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  private func handle(_ activity: CFRunLoopActivity) {
    let now = DispatchTime.now().uptimeNanoseconds
    if activity.contains(.afterWaiting) {
      turnStart = now
      return
    }
    guard let start = turnStart else { return }
    turnStart = nil
    let duration = now - start
    guard duration >= threshold else { return }
    let milliseconds = Double(duration) / 1_000_000
    Self.logger.notice(
      "Main thread stall: \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    PerfSignpost.event("main.stall")
  }
}
