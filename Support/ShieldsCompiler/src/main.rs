use adblock::content_blocking::{CbRule, CbType};
use adblock::lists::{FilterFormat, FilterSet, ParseOptions};
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::io::{self, Read};

#[derive(Debug, Deserialize)]
struct CompilerInput {
    subscriptions: Vec<CompilerSubscription>,
}

#[derive(Debug, Deserialize)]
struct CompilerSubscription {
    id: String,
    text: String,
    format: String,
}

#[derive(Debug, Serialize)]
struct CompilerOutput {
    #[serde(rename = "rulesJSON")]
    rules_json: String,
    #[serde(rename = "totalRuleCount")]
    total_rule_count: usize,
    #[serde(rename = "networkRuleCount")]
    network_rule_count: usize,
    #[serde(rename = "cosmeticRuleCount")]
    cosmetic_rule_count: usize,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let mut stdin = String::new();
    io::stdin().read_to_string(&mut stdin)?;
    let input: CompilerInput = serde_json::from_str(&stdin)?;

    let mut filters = FilterSet::new(true);
    for subscription in input.subscriptions {
        let options = ParseOptions {
            format: parse_format(&subscription.format),
            ..ParseOptions::default()
        };
        let _ = &subscription.id;
        filters.add_filter_list(&subscription.text, options);
    }

    let (rules, _) = filters
        .into_content_blocking()
        .map_err(|_| "unable to translate filters into WebKit content blockers")?;

    let ascii_rules: Vec<CbRule> = rules
        .into_iter()
        .filter(rule_is_ascii_serializable)
        .collect();

    let total_rule_count = ascii_rules.len();
    let cosmetic_rule_count = ascii_rules
        .iter()
        .filter(|rule| matches!(rule.action.typ, CbType::CssDisplayNone))
        .count();
    let network_rule_count = ascii_rules
        .iter()
        .filter(|rule| !matches!(rule.action.typ, CbType::CssDisplayNone))
        .count();

    let rules_json = serde_json::to_string(&ascii_rules)?;
    let output = CompilerOutput {
        rules_json,
        total_rule_count,
        network_rule_count,
        cosmetic_rule_count,
    };

    println!("{}", serde_json::to_string(&output)?);
    Ok(())
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
