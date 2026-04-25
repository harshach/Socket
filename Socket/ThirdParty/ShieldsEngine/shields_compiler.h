//
//  shields_compiler.h
//
//  C ABI for Socket's shields_compiler Rust static library. Mirrors the
//  extern "C" functions exported by Support/ShieldsCompiler/src/lib.rs.
//  Swift reaches these via a module.modulemap (see ShieldsEngine.swift).
//

#ifndef SHIELDS_COMPILER_H
#define SHIELDS_COMPILER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Compile a JSON-encoded list of subscriptions into WKContentRuleList JSON.
///
/// Input shape (matches Support/ShieldsCompiler/src/lib.rs::CompilerInput):
///     { "subscriptions": [ { "id": "...", "text": "...", "format": "standard"|"hosts" }, ... ] }
///
/// Output shape on success:
///     { "rulesJSON": "...", "totalRuleCount": N, "networkRuleCount": N, "cosmeticRuleCount": N }
/// On error:
///     { "error": "..." }
///
/// The returned pointer owns a null-terminated UTF-8 C string the caller
/// MUST free via `shields_free_string`. Returns NULL only for allocation
/// failures inside the Rust runtime (which in practice won't happen for
/// JSON payloads since they never contain interior NULs).
char *shields_compile(const char *input_json);

/// Free a string returned by `shields_compile`. Passing NULL is a no-op.
void shields_free_string(char *ptr);

/// Query the runtime adblock-rust Engine for cosmetic resources (selectors,
/// scriptlets) matching `url`. Returns a JSON-encoded `CosmeticQueryOutput`:
///     { "hide_selectors": [...], "procedural_actions": [...],
///       "exceptions": [...], "injected_script": "...", "generichide": false }
/// Returns the same shape with empty arrays / empty string when the engine
/// hasn't been initialised yet. Free the returned pointer via
/// `shields_free_string`.
char *shields_query_cosmetic(const char *url);

#ifdef __cplusplus
}
#endif

#endif /* SHIELDS_COMPILER_H */
