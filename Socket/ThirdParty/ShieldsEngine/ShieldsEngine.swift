//
//  ShieldsEngine.swift
//
//  In-process Swift wrapper around the `shields_compiler` Rust staticlib.
//  Replaces the Process-based `compileWithRustHelper` in
//  TrackingProtectionManager with a direct C FFI call — same JSON contract,
//  no subprocess spawn, no cargo-at-runtime dependency.
//
//  The subprocess path in TrackingProtectionManager remains as a fallback
//  behind a feature flag (see Settings.useShieldsEngineFFI).
//

import Foundation
import os
import ShieldsCompilerFFI

/// Matches `CompilerOutput` in Support/ShieldsCompiler/src/lib.rs.
struct ShieldsEngineOutput: Decodable, Sendable {
    let rulesJSON: String
    let totalRuleCount: Int
    let networkRuleCount: Int
    let cosmeticRuleCount: Int
}

/// Error surface from the engine. Wraps both Rust-side errors (returned as
/// `{"error":"..."}` JSON) and Swift-side JSON / UTF-8 failures.
enum ShieldsEngineError: Error, CustomStringConvertible {
    case invalidInputEncoding
    case rustSideError(String)
    case invalidOutputEncoding
    case decodeFailure(Error)

    var description: String {
        switch self {
        case .invalidInputEncoding:
            return "Input could not be UTF-8 encoded for the shields engine"
        case .rustSideError(let msg):
            return "shields engine: \(msg)"
        case .invalidOutputEncoding:
            return "shields engine returned non-UTF-8 output"
        case .decodeFailure(let err):
            return "shields engine output did not match expected shape: \(err.localizedDescription)"
        }
    }
}

/// Thin, thread-safe Swift facade over `shields_compile` / `shields_free_string`.
/// Methods are blocking but cheap to call off the main actor; typical
/// compile times are tens to hundreds of ms for EasyList-sized input.
final class ShieldsEngine: @unchecked Sendable {
    static let shared = ShieldsEngine()

    private static let logger = Logger(
        subsystem: "com.socket.browser",
        category: "ShieldsEngine"
    )

    private init() {}

    /// Run the compiler on a raw JSON payload (matches `CompilerInput` in
    /// the Rust crate). Suitable for callers that already have the
    /// subprocess-compatible JSON ready.
    func compile(rawJSON: String) throws -> ShieldsEngineOutput {
        let started = Date()

        // rawJSON must round-trip cleanly to UTF-8; withCString handles
        // that for us and passes a null-terminated C string to Rust.
        let rawOutput: String = try rawJSON.withCString { inputPtr -> String in
            guard let outPtr = shields_compile(inputPtr) else {
                throw ShieldsEngineError.invalidInputEncoding
            }
            defer { shields_free_string(outPtr) }
            guard let swiftString = String(validatingCString: outPtr) else {
                throw ShieldsEngineError.invalidOutputEncoding
            }
            return swiftString
        }

        // Rust returns either `CompilerOutput` JSON or `{"error":"..."}`.
        // Peek at the error path first to surface a clean message.
        if let data = rawOutput.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String {
            throw ShieldsEngineError.rustSideError(err)
        }

        do {
            let output = try JSONDecoder().decode(
                ShieldsEngineOutput.self,
                from: Data(rawOutput.utf8)
            )
            let elapsed = Date().timeIntervalSince(started)
            Self.logger.info(
                "compiled \(output.totalRuleCount) rules (\(output.networkRuleCount) network / \(output.cosmeticRuleCount) cosmetic) in \(String(format: "%.3fs", elapsed), privacy: .public)"
            )
            return output
        } catch {
            throw ShieldsEngineError.decodeFailure(error)
        }
    }
}
