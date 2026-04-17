//! shields_compiler CLI — subprocess fallback for Socket's tracking
//! protection compiler. Reads a JSON payload on stdin, writes the compiled
//! output on stdout, exits 1 with the error on stderr. All the real work
//! lives in `lib.rs`; this file is the subprocess entry point kept around
//! for environments where the Swift side can't link the static library.

use std::io::{self, Read};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut stdin = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut stdin) {
        eprintln!("failed to read stdin: {error}");
        return ExitCode::from(1);
    }
    match shields_compiler::compile_json(&stdin) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}
