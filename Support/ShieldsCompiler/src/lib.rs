//! shields_compiler
//!
//! Shared core for converting Adblock Plus / EasyList–style filter lists into
//! WebKit `WKContentRuleList` JSON, plus a C ABI so Swift can call it
//! in-process without spawning a subprocess.
//!
//! Two public entry points:
//!
//! * [`compile`] — pure Rust, used by `main.rs` (the subprocess fallback)
//! * [`shields_compile`] / [`shields_free_string`] — `extern "C"` ABI used by
//!   Swift through `Socket/ThirdParty/ShieldsEngine/ShieldsEngine.swift`.
//!
//! Both paths parse the same input JSON, run the same adblock-rust pipeline,
//! and return the same output JSON. Swift never parses Rust data structures
//! directly; we stick to JSON so the wire format is identical between the
//! FFI and subprocess paths and swapping between them is trivial.

use adblock::content_blocking::{CbRule, CbType};
use adblock::lists::{FilterFormat, FilterSet, ParseOptions};
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic;

// ===== Wire format =====

#[derive(Debug, Deserialize)]
pub struct CompilerInput {
    pub subscriptions: Vec<CompilerSubscription>,
}

#[derive(Debug, Deserialize)]
pub struct CompilerSubscription {
    #[allow(dead_code)]
    pub id: String,
    pub text: String,
    pub format: String,
}

#[derive(Debug, Serialize)]
pub struct CompilerOutput {
    #[serde(rename = "rulesJSON")]
    pub rules_json: String,
    /// Mirror of `rulesJSON` containing the same triggers but with the
    /// `notify` action instead of `block`. Installed as a SECOND
    /// `WKContentRuleList` alongside the blocker so each blocked URL
    /// fires a `_content-blocker:notify-rule_` event on the page —
    /// the Shields-content-world script consumes this to update real
    /// per-tab block counts. Cosmetic (`css-display-none`) rules are
    /// excluded since they aren't network blocks.
    #[serde(rename = "notifyRulesJSON")]
    pub notify_rules_json: String,
    #[serde(rename = "totalRuleCount")]
    pub total_rule_count: usize,
    #[serde(rename = "networkRuleCount")]
    pub network_rule_count: usize,
    #[serde(rename = "cosmeticRuleCount")]
    pub cosmetic_rule_count: usize,
}

#[derive(Debug, Serialize)]
pub struct CompilerError {
    pub error: String,
}

// ===== Core compilation =====

/// Run the adblock-rust pipeline. Takes a parsed [`CompilerInput`] and
/// returns the compiled [`CompilerOutput`] or an error message.
pub fn compile(input: CompilerInput) -> Result<CompilerOutput, Box<dyn Error>> {
    let mut filters = FilterSet::new(true);
    for subscription in input.subscriptions {
        let options = ParseOptions {
            format: parse_format(&subscription.format),
            ..ParseOptions::default()
        };
        filters.add_filter_list(&subscription.text, options);
    }

    let (rules, _) = filters
        .into_content_blocking()
        .map_err(|_| "unable to translate filters into WebKit content blockers")?;

    // WKContentRuleListStore rejects non-ASCII rules in practice (it balks
    // at certain Unicode in `url-filter`). Filter here so the Swift side
    // doesn't have to guess why compileContentRuleList fails.
    let ascii_rules: Vec<CbRule> = rules
        .into_iter()
        .filter(rule_is_ascii_serializable)
        .collect();

    let total_rule_count = ascii_rules.len();
    let cosmetic_rule_count = ascii_rules
        .iter()
        .filter(|rule| matches!(rule.action.typ, CbType::CssDisplayNone))
        .count();
    let network_rule_count = total_rule_count - cosmetic_rule_count;

    // Build a notify-action mirror of the network-block rules. We hand
    // WebKit two compiled rule lists: the original (which actually blocks)
    // and this mirror (which only fires `notify` events). The page sees
    // both — block kills the request, notify gives our content-world
    // script a `_content-blocker:notify-rule_` event so per-tab stats
    // can reflect real activity instead of the static rule-list size.
    let notify_rules_json = serde_json::to_string(&build_notify_mirror(&ascii_rules))?;

    let rules_json = serde_json::to_string(&ascii_rules)?;
    Ok(CompilerOutput {
        rules_json,
        notify_rules_json,
        total_rule_count,
        network_rule_count,
        cosmetic_rule_count,
    })
}

/// Produce a notify-action mirror of `rules`, dropping cosmetic rules
/// (they don't represent network blocks) and any `IgnorePreviousRules`
/// entries (their semantics don't carry to a notify-only list).
fn build_notify_mirror(rules: &[CbRule]) -> Vec<serde_json::Value> {
    use serde_json::json;
    rules
        .iter()
        .filter(|rule| matches!(rule.action.typ, CbType::Block | CbType::MakeHttps))
        .filter_map(|rule| {
            // Re-serialize the trigger then swap the action. Going through
            // serde_json::Value avoids a hard dependency on every CbTrigger
            // field and keeps us forward-compatible with adblock-rust
            // additions.
            let mut obj = serde_json::to_value(rule).ok()?;
            // WKContentRuleList notify-action shape:
            //   { "type": "notify", "notification": "<identifier>" }
            // The identifier is delivered to the page in the
            // `_WKWebExtensionContentBlocker` event payload. We use a
            // stable token; the Shields content-world script just counts
            // the events, it doesn't need to differentiate per-rule.
            obj.as_object_mut()?
                .insert("action".to_string(), json!({ "type": "notify", "notification": "socketShields" }));
            Some(obj)
        })
        .collect()
}

/// Parse a JSON input string, run [`compile`], and return the result as
/// JSON. Used by both the CLI (via stdin) and the C FFI.
pub fn compile_json(input_json: &str) -> Result<String, Box<dyn Error>> {
    let input: CompilerInput = serde_json::from_str(input_json)?;
    let output = compile(input)?;
    Ok(serde_json::to_string(&output)?)
}

fn parse_format(value: &str) -> FilterFormat {
    match value {
        "hosts" => FilterFormat::Hosts,
        _ => FilterFormat::Standard,
    }
}

fn rule_is_ascii_serializable(rule: &CbRule) -> bool {
    serde_json::to_string(rule)
        .map(|encoded| encoded.is_ascii())
        .unwrap_or(false)
}

// ===== C FFI =====

/// Compile the filter lists supplied as a UTF-8 JSON string.
///
/// - `input_json` must be a non-null, null-terminated C string containing
///   [`CompilerInput`] JSON.
/// - Returns a newly allocated, null-terminated C string that the caller
///   MUST free via [`shields_free_string`]. On any error (null input,
///   invalid UTF-8, parse failure, panic inside the adblock engine) the
///   returned string contains a JSON object `{"error": "..."}`.
/// - Never returns null; null is reserved for catastrophic allocation
///   failure in `CString::new`, which would only happen if `output_json`
///   contained an interior NUL (it won't — it's JSON).
///
/// # Safety
/// `input_json` must outlive the call and point to valid UTF-8. The
/// returned pointer is valid until passed to `shields_free_string`.
#[no_mangle]
pub unsafe extern "C" fn shields_compile(input_json: *const c_char) -> *mut c_char {
    let result = panic::catch_unwind(|| {
        if input_json.is_null() {
            return error_json("null input");
        }
        let c_str = CStr::from_ptr(input_json);
        let input_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return error_json("input is not valid UTF-8"),
        };
        match compile_json(input_str) {
            Ok(json) => json,
            Err(error) => error_json(&error.to_string()),
        }
    });
    let payload = result.unwrap_or_else(|_| error_json("shields_compiler panicked"));
    match CString::new(payload) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Free a string returned by [`shields_compile`].
///
/// # Safety
/// `ptr` must have been returned by [`shields_compile`] and not already
/// freed. Passing null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn shields_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    // Reconstruct the CString so Rust drops it properly.
    let _ = CString::from_raw(ptr);
}

/// Build a JSON error payload matching [`CompilerError`].
fn error_json(message: &str) -> String {
    let payload = CompilerError {
        error: message.to_string(),
    };
    serde_json::to_string(&payload)
        .unwrap_or_else(|_| "{\"error\":\"unserializable error\"}".to_string())
}
