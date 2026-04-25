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
    /// Notify-action mirror — see `CompilerOutput` in lib.rs. Optional so
    /// older Rust binaries that don't emit it still decode.
    let notifyRulesJSON: String?
    let totalRuleCount: Int
    let networkRuleCount: Int
    let cosmeticRuleCount: Int
}

/// Matches `CosmeticQueryOutput` in Support/ShieldsCompiler/src/lib.rs.
/// Returned by `ShieldsEngine.queryCosmetic(url:)` for per-navigation
/// scriptlet + cosmetic injection.
struct CosmeticQueryOutput: Decodable, Sendable {
    let hideSelectors: [String]
    let proceduralActions: [String]
    let exceptions: [String]
    let injectedScript: String
    let generichide: Bool

    enum CodingKeys: String, CodingKey {
        case hideSelectors = "hide_selectors"
        case proceduralActions = "procedural_actions"
        case exceptions
        case injectedScript = "injected_script"
        case generichide
    }

    static let empty = CosmeticQueryOutput(
        hideSelectors: [],
        proceduralActions: [],
        exceptions: [],
        injectedScript: "",
        generichide: false
    )
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
        let signpostState = PerfSignpost.shields.beginInterval("ShieldsEngine.compile")
        defer { PerfSignpost.shields.endInterval("ShieldsEngine.compile", signpostState) }

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

    /// Query the runtime engine for cosmetic resources + scriptlets that
    /// apply to `url`. Returns `.empty` rather than throwing on the
    /// "engine not yet built" path since that's a normal cold-start
    /// state, not an error condition. Safe to call from any thread.
    func queryCosmetic(url: String) -> CosmeticQueryOutput {
        let rawOutput: String? = url.withCString { inputPtr in
            guard let outPtr = shields_query_cosmetic(inputPtr) else { return nil }
            defer { shields_free_string(outPtr) }
            return String(validatingCString: outPtr)
        }
        guard let raw = rawOutput, let data = raw.data(using: .utf8) else {
            return .empty
        }
        // Surface a Rust-side error JSON as an empty result — the caller
        // is on the navigation hot path and can't usefully recover.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["error"] != nil {
            return .empty
        }
        return (try? JSONDecoder().decode(CosmeticQueryOutput.self, from: data)) ?? .empty
    }
}
