//
//  ExtensionTelemetry.swift
//  Socket
//
//  Structured lifecycle/error events for the extension subsystem. Routes to
//  os.Logger with stable field shape plus an in-memory ring buffer that a debug
//  surface can tail. Deliberately zero dependencies beyond Foundation + os.
//

import Foundation
import os

/// Stable set of extension-subsystem events. Stringly-typed on purpose so it
/// round-trips cleanly to logs and telemetry collectors.
enum ExtensionEvent: String {
    case installStarted
    case installSucceeded
    case installFailed
    case uninstallStarted
    case uninstallSucceeded
    case uninstallFailed
    case loaded
    case unloaded
    case backgroundStarted
    case backgroundFailed
    case popupOpened
    case popupDismissed
    case permissionGranted
    case permissionDenied
    case shimCallFailed
    case zipRejected
    case manifestRejected
}

/// Structured severity. Maps to os_log levels; telemetry sinks can filter.
enum ExtensionEventSeverity: String {
    case info
    case warning
    case error
}

/// One recorded event. Fields are flat scalars so JSON-encoding stays trivial.
struct ExtensionEventRecord: Sendable {
    let timestamp: Date
    let event: ExtensionEvent
    let severity: ExtensionEventSeverity
    let extensionId: String?
    let extensionName: String?
    let message: String?
    let context: [String: String]
}

/// Lightweight telemetry emitter. All calls are thread-safe and non-blocking:
/// the ring buffer uses an `OSAllocatedUnfairLock` to keep contention cheap, and
/// the actual logging is a plain os_log write. No async hops.
///
/// Intended usage:
/// ```
/// ExtensionTelemetry.shared.record(.installSucceeded,
///                                  extensionId: id,
///                                  extensionName: name)
/// ```
final class ExtensionTelemetry: @unchecked Sendable {
    static let shared = ExtensionTelemetry()

    /// Max events kept in the in-memory ring. 500 covers typical debugging
    /// windows without growing unbounded for long-running sessions.
    private static let ringCapacity = 500

    private let logger = Logger(subsystem: "com.socket.browser",
                                category: "ExtensionTelemetry")
    private let lock = OSAllocatedUnfairLock<[ExtensionEventRecord]>(initialState: [])

    private init() {}

    func record(_ event: ExtensionEvent,
                severity: ExtensionEventSeverity = .info,
                extensionId: String? = nil,
                extensionName: String? = nil,
                message: String? = nil,
                context: [String: String] = [:]) {
        let record = ExtensionEventRecord(
            timestamp: Date(),
            event: event,
            severity: severity,
            extensionId: extensionId,
            extensionName: extensionName,
            message: message,
            context: context
        )

        appendToRing(record)
        emitToLogger(record)
    }

    /// Snapshot of the ring buffer, newest events last. Used by diagnostic UI.
    func snapshot() -> [ExtensionEventRecord] {
        lock.withLock { $0 }
    }

    /// Clear the ring. Exposed so a debug panel's "clear" button has a hook.
    func clear() {
        lock.withLock { $0.removeAll(keepingCapacity: true) }
    }

    // MARK: - Internals

    private func appendToRing(_ record: ExtensionEventRecord) {
        lock.withLock { buffer in
            buffer.append(record)
            if buffer.count > Self.ringCapacity {
                buffer.removeFirst(buffer.count - Self.ringCapacity)
            }
        }
    }

    private func emitToLogger(_ record: ExtensionEventRecord) {
        let idField = record.extensionId ?? "-"
        let nameField = record.extensionName ?? "-"
        let msgField = record.message ?? ""
        let contextField = record.context.isEmpty
            ? ""
            : " " + record.context.map { "\($0.key)=\($0.value)" }
                                   .sorted()
                                   .joined(separator: " ")

        switch record.severity {
        case .info:
            logger.info("ext.\(record.event.rawValue) id=\(idField, privacy: .public) name=\(nameField, privacy: .public) \(msgField, privacy: .public)\(contextField, privacy: .public)")
        case .warning:
            logger.warning("ext.\(record.event.rawValue) id=\(idField, privacy: .public) name=\(nameField, privacy: .public) \(msgField, privacy: .public)\(contextField, privacy: .public)")
        case .error:
            logger.error("ext.\(record.event.rawValue) id=\(idField, privacy: .public) name=\(nameField, privacy: .public) \(msgField, privacy: .public)\(contextField, privacy: .public)")
        }
    }
}
